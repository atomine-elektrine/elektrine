defmodule Elektrine.ActivityPub.ProcessActivityWorker do
  @moduledoc """
  Oban worker for processing incoming ActivityPub activities.

  Activities are enqueued when received at the inbox and processed
  asynchronously with automatic retries on failure.

  Uses Lemmy-style per-domain throttling to prevent one noisy instance
  from overwhelming the system.

  Deduplication is handled via fast ETS lookup instead of Oban's database-based
  uniqueness constraint to avoid the 700-1200ms latency caused by DB queries
  under high federation load.
  """

  use Oban.Worker,
    queue: :activitypub,
    max_attempts: 3

  # NOTE: Removed Oban uniqueness constraint - using ETS deduplication instead
  # unique: [period: 60, fields: [:args], keys: [:activity_id]]

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Handler
  alias Elektrine.ActivityPub.DomainThrottler
  alias Elektrine.Telemetry.Events

  # Deduplication window in seconds
  @dedup_window_seconds 60

  # Maximum age of a job before we discard it (prevents infinite snooze loops)
  # Jobs older than 10 minutes are stale and should be dropped
  @max_job_age_seconds 600
  # Keep throttling/backoff churn bounded so Oban doesn't become the bottleneck.
  @max_throttle_snoozes 3
  @throttle_snooze_seconds 30
  @max_throttled_job_age_seconds 120
  @max_backoff_job_age_seconds 120

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"activity" => activity, "actor_uri" => actor_uri} = args,
        inserted_at: inserted_at,
        attempt: attempt
      }) do
    started_at = System.monotonic_time(:millisecond)
    target_user_id = args["target_user_id"]
    activity_type = activity["type"] || "unknown"
    domain = actor_domain(actor_uri)

    # Discard jobs that are too old (prevents infinite snooze loops)
    job_age = DateTime.diff(DateTime.utc_now(), inserted_at, :second)

    if job_age > @max_job_age_seconds do
      Logger.warning("Activity #{activity["id"]} too old (#{job_age}s), discarding")

      emit_perform_telemetry(started_at, activity_type, domain, :discarded_stale, %{
        job_age_seconds: job_age
      })

      :ok
    else
      # Check if instance is blocked first
      if ActivityPub.instance_blocked?(domain) do
        Logger.info("Rejected activity from blocked instance: #{domain}")
        emit_perform_telemetry(started_at, activity_type, domain, :blocked_instance)
        :ok
      else
        # Try to acquire a processing slot for this domain (Lemmy-style)
        case DomainThrottler.acquire(domain) do
          {:ok, :acquired} ->
            # Got a slot, process the activity
            result = process_activity(activity, actor_uri, target_user_id)

            # Release slot with success/failure status
            success? = match?(:ok, result)
            DomainThrottler.release(domain, success?)

            outcome =
              case result do
                :ok -> :processed
                {:error, _reason} -> :processing_failed
              end

            emit_perform_telemetry(started_at, activity_type, domain, outcome)
            result

          {:error, :throttled} ->
            handle_throttled(activity, domain, attempt, job_age, started_at, activity_type)

          {:error, :backoff, remaining_ms} ->
            handle_backoff(
              activity,
              domain,
              attempt,
              job_age,
              remaining_ms,
              started_at,
              activity_type
            )
        end
      end
    end
  end

  defp process_activity(activity, actor_uri, target_user_id) do
    started_at = System.monotonic_time(:millisecond)

    # Get target user if specified
    target_user =
      if target_user_id do
        Elektrine.Repo.get(Elektrine.Accounts.User, target_user_id)
      else
        nil
      end

    # Process the activity using the handler
    case Handler.process_activity_async(activity, actor_uri, target_user) do
      {:ok, _result} ->
        Logger.debug("Successfully processed activity #{activity["id"]}")
        emit_handler_telemetry(activity, actor_uri, :success, started_at)
        :ok

      {:error, reason}
      when reason in [
             :handle_like_failed,
             :handle_emoji_react_failed,
             :handle_dislike_failed,
             :fetch_failed,
             :http_error,
             :not_found
           ] ->
        # These are expected when remote instances react to posts we don't have - don't retry
        Logger.debug("Activity #{activity["id"]} failed (#{reason}), not retrying")

        emit_handler_telemetry(activity, actor_uri, :ignored, started_at, %{
          reason: reason
        })

        :ok

      {:error, reason} ->
        Logger.warning("Failed to process activity #{activity["id"]}: #{inspect(reason)}")

        emit_handler_telemetry(activity, actor_uri, :failure, started_at, %{
          reason: reason
        })

        # Return error to trigger retry
        {:error, reason}
    end
  end

  defp handle_throttled(activity, domain, attempt, job_age, started_at, activity_type) do
    if attempt <= @max_throttle_snoozes and job_age <= @max_throttled_job_age_seconds do
      Logger.debug("Throttled activity from #{domain}, snoozing for #{@throttle_snooze_seconds}s")
      emit_perform_telemetry(started_at, activity_type, domain, :throttled)
      {:snooze, @throttle_snooze_seconds}
    else
      Logger.warning(
        "Dropping throttled activity #{activity["id"]} from #{domain} (attempt=#{attempt}, age=#{job_age}s)"
      )

      emit_perform_telemetry(started_at, activity_type, domain, :discarded_throttled, %{
        attempt: attempt,
        job_age_seconds: job_age
      })

      :ok
    end
  end

  defp handle_backoff(activity, domain, attempt, job_age, remaining_ms, started_at, activity_type) do
    if attempt <= @max_throttle_snoozes and job_age <= @max_backoff_job_age_seconds do
      snooze_seconds = max(@throttle_snooze_seconds, div(remaining_ms, 1000))
      Logger.info("Domain #{domain} in backoff, snoozing for #{snooze_seconds}s")

      emit_perform_telemetry(started_at, activity_type, domain, :backoff, %{
        backoff_ms: remaining_ms,
        attempt: attempt
      })

      {:snooze, snooze_seconds}
    else
      Logger.warning(
        "Dropping backoff activity #{activity["id"]} from #{domain} (attempt=#{attempt}, age=#{job_age}s)"
      )

      emit_perform_telemetry(started_at, activity_type, domain, :discarded_backoff, %{
        backoff_ms: remaining_ms,
        attempt: attempt,
        job_age_seconds: job_age
      })

      :ok
    end
  end

  @doc """
  Enqueues an activity for processing.

  Returns {:ok, job} on success or {:ok, :skipped} if the activity type should be skipped.
  """
  def enqueue(activity, actor_uri, target_user \\ nil) do
    activity_id = activity["id"]
    start_time = System.monotonic_time(:millisecond)
    activity_type = activity["type"] || "unknown"

    # Fast ETS-based deduplication (O(1) instead of database query)
    if activity_id && already_seen?(activity_id) do
      Events.federation(:inbox_worker, :enqueue, :duplicate, nil, %{
        activity_type: activity_type,
        actor_domain: actor_domain(actor_uri)
      })

      {:ok, :duplicate}
    else
      # Mark as seen before inserting (prevents race conditions)
      if activity_id, do: mark_seen(activity_id)

      dedup_time = System.monotonic_time(:millisecond) - start_time

      args = %{
        "activity" => activity,
        "actor_uri" => actor_uri,
        "activity_id" => activity_id,
        "target_user_id" => target_user && target_user.id
      }

      # Priority: 0 = highest, 3 = lowest
      # Content activities (Create, Update) get priority 0
      # Votes (Like, Dislike, EmojiReact) get priority 2 (lower priority)
      # Announces need to check inner object type
      priority = activity_priority(activity)

      insert_start = System.monotonic_time(:millisecond)

      result =
        args
        |> new(priority: priority)
        |> Oban.insert()

      insert_time = System.monotonic_time(:millisecond) - insert_start

      # Log if Oban insert is slow (> 50ms)
      if insert_time > 50 do
        Logger.warning("Slow Oban.insert: dedup=#{dedup_time}ms insert=#{insert_time}ms")
      end

      enqueue_duration = System.monotonic_time(:millisecond) - start_time

      case result do
        {:ok, _job} ->
          Events.federation(:inbox_worker, :enqueue, :success, enqueue_duration, %{
            activity_type: activity_type,
            actor_domain: actor_domain(actor_uri),
            priority: priority,
            dedup_ms: dedup_time,
            insert_ms: insert_time
          })

        {:error, reason} ->
          Events.federation(:inbox_worker, :enqueue, :failure, enqueue_duration, %{
            activity_type: activity_type,
            actor_domain: actor_domain(actor_uri),
            priority: priority,
            reason: inspect(reason),
            dedup_ms: dedup_time,
            insert_ms: insert_time
          })
      end

      result
    end
  end

  # ETS-based activity deduplication for fast O(1) lookups
  # Much faster than Oban's database-based uniqueness constraint

  defp ensure_dedup_table do
    case :ets.whereis(:activitypub_dedup) do
      :undefined ->
        try do
          :ets.new(:activitypub_dedup, [:named_table, :public, :set, {:write_concurrency, true}])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp already_seen?(activity_id) do
    ensure_dedup_table()
    now = System.system_time(:second)
    cutoff = now - @dedup_window_seconds

    case :ets.lookup(:activitypub_dedup, activity_id) do
      [{^activity_id, timestamp}] when timestamp > cutoff -> true
      _ -> false
    end
  end

  defp mark_seen(activity_id) do
    ensure_dedup_table()
    now = System.system_time(:second)
    :ets.insert(:activitypub_dedup, {activity_id, now})

    # Periodically clean old entries (1% chance per insert)
    if :rand.uniform(100) == 1 do
      cleanup_old_entries()
    end
  end

  defp cleanup_old_entries do
    cutoff = System.system_time(:second) - @dedup_window_seconds

    try do
      :ets.select_delete(:activitypub_dedup, [
        {{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
      ])
    rescue
      ArgumentError -> :ok
    end
  end

  # Determine job priority based on activity type
  # Lower number = higher priority (processed first)
  defp activity_priority(%{"type" => type} = activity) do
    case type do
      # High priority - content creation
      "Create" -> 0
      "Update" -> 0
      "Delete" -> 0
      # Medium priority - social graph
      "Follow" -> 1
      "Accept" -> 1
      "Reject" -> 1
      "Undo" -> 1
      "Block" -> 1
      # Low priority - votes and reactions (high volume)
      "Like" -> 2
      "Dislike" -> 2
      "EmojiReact" -> 2
      # Announces depend on inner object
      "Announce" -> announce_priority(activity)
      # Default medium priority
      _ -> 1
    end
  end

  # Announces of content get high priority, announces of votes get low priority
  defp announce_priority(%{"object" => object}) when is_map(object) do
    case object["type"] do
      type when type in ["Note", "Page", "Article", "Create", "Update", "Delete"] -> 0
      type when type in ["Like", "Dislike", "EmojiReact"] -> 2
      _ -> 1
    end
  end

  defp announce_priority(_), do: 1

  defp emit_handler_telemetry(activity, actor_uri, outcome, started_at, metadata \\ %{}) do
    Events.federation(
      :inbox_worker,
      :handler,
      outcome,
      System.monotonic_time(:millisecond) - started_at,
      Map.merge(metadata, %{
        activity_type: activity["type"] || "unknown",
        actor_domain: actor_domain(actor_uri)
      })
    )
  end

  defp emit_perform_telemetry(started_at, activity_type, domain, outcome, metadata \\ %{}) do
    Events.federation(
      :inbox_worker,
      :perform,
      outcome,
      System.monotonic_time(:millisecond) - started_at,
      Map.merge(metadata, %{
        activity_type: activity_type,
        actor_domain: domain || "unknown"
      })
    )
  end

  defp actor_domain(nil), do: "unknown"

  defp actor_domain(actor_uri) when is_binary(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "unknown"
    end
  end

  defp actor_domain(_), do: "unknown"
end
