defmodule Elektrine.ActivityPub.InboxQueue do
  @moduledoc """
  Fast in-memory queue for incoming ActivityPub activities.

  Instead of calling Oban.insert() for every /inbox request (which requires
  a database connection), activities are queued in ETS and batch-inserted
  into Oban periodically. This removes the database from the /inbox hot path.

  Performance improvement: ~1000ms → ~5ms per /inbox request
  """

  use GenServer
  require Logger

  alias Elektrine.Telemetry.Events

  @table_name :inbox_activity_queue
  # Flush every 500ms
  @flush_interval 500
  # Max activities per batch insert
  @max_batch_size 25
  # Keep DB checkout times short by splitting large inserts
  @insert_chunk_size 5
  # Start shedding low-priority traffic if backlog grows too large
  @max_queue_size 5_000
  @activity_drop_keys ["contentMap"]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueue an activity for processing. Returns immediately without hitting the database.
  """
  def enqueue(activity, actor_uri, target_user_id) do
    activity_id = activity["id"]
    activity_type = activity["type"] || "unknown"

    cond do
      # Fast dedup check
      activity_id && already_queued?(activity_id) ->
        Events.federation(:inbox_queue, :enqueue, :duplicate, nil, %{
          activity_type: activity_type
        })

        {:ok, :duplicate}

      overload_drop?(activity) ->
        Events.federation(:inbox_queue, :enqueue, :shed, nil, %{
          activity_type: activity_type,
          actor_domain: actor_domain(actor_uri)
        })

        # Return success so remote senders don't retry aggressively.
        {:ok, :shed}

      true ->
        # Mark as queued and add to queue
        if activity_id, do: mark_queued(activity_id)

        item = %{
          activity: activity,
          actor_uri: actor_uri,
          target_user_id: target_user_id,
          activity_id: activity_id,
          queued_at: System.system_time(:millisecond)
        }

        :ets.insert(@table_name, {make_ref(), item})

        Events.federation(:inbox_queue, :enqueue, :queued, nil, %{
          activity_type: activity_type,
          has_target_user: not is_nil(target_user_id),
          actor_domain: actor_domain(actor_uri)
        })

        {:ok, :queued}
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@table_name, [:named_table, :public, :set, {:write_concurrency, true}])
    :ets.new(:inbox_dedup, [:named_table, :public, :set, {:write_concurrency, true}])

    # Schedule first flush
    schedule_flush()

    Logger.info("InboxQueue started - activities will be batched every #{@flush_interval}ms")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush_queue()
    schedule_flush()
    {:noreply, state}
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end

  defp flush_queue do
    # Take up to max_batch_size items directly from ETS without copying the whole table.
    items = take_batch(@max_batch_size)

    if items != [] do
      flush_started_at = System.monotonic_time(:millisecond)
      flush_result = insert_in_chunks(items)
      flush_duration = System.monotonic_time(:millisecond) - flush_started_at

      case flush_result do
        {:ok, inserted_count} ->
          Logger.debug("InboxQueue flushed #{inserted_count} activities")

          Events.federation(
            :inbox_queue,
            :flush,
            :success,
            flush_duration,
            %{
              batch_size: inserted_count
            }
          )

        {:error, reason, inserted_count, failed_items} ->
          Logger.error("InboxQueue flush failed after #{inserted_count} inserts: #{inspect(reason)}")

          Events.federation(
            :inbox_queue,
            :flush,
            :failure,
            flush_duration,
            %{
              batch_size: length(items),
              inserted_count: inserted_count,
              requeued_count: length(failed_items),
              reason: inspect(reason)
            }
          )

          # Re-queue only the items that were not successfully inserted.
          Enum.each(failed_items, fn item ->
            :ets.insert(@table_name, {make_ref(), item})
          end)
      end

      # Clean up old dedup entries periodically
      cleanup_dedup()
    end
  end

  defp take_batch(limit) when is_integer(limit) and limit > 0 do
    do_take_batch(limit, :ets.first(@table_name), [])
  end

  defp take_batch(_), do: []

  defp do_take_batch(0, _key, acc), do: Enum.reverse(acc)
  defp do_take_batch(_remaining, :"$end_of_table", acc), do: Enum.reverse(acc)

  defp do_take_batch(remaining, key, acc) do
    next_key = :ets.next(@table_name, key)

    case :ets.take(@table_name, key) do
      [{^key, item}] ->
        do_take_batch(remaining - 1, next_key, [item | acc])

      [] ->
        do_take_batch(remaining, next_key, acc)
    end
  end

  defp insert_in_chunks(items) when is_list(items) do
    chunks = Enum.chunk_every(items, @insert_chunk_size)
    do_insert_chunks(chunks, 0)
  end

  defp do_insert_chunks([], inserted_count), do: {:ok, inserted_count}

  defp do_insert_chunks([chunk | rest], inserted_count) do
    jobs = Enum.map(chunk, &build_job/1)

    case safe_insert_all(jobs) do
      {:ok, inserted} ->
        do_insert_chunks(rest, inserted_count + length(inserted))

      {:error, reason} ->
        failed_items = List.flatten([chunk | rest])
        {:error, reason, inserted_count, failed_items}
    end
  end

  defp safe_insert_all(jobs) do
    try do
      {:ok, Oban.insert_all(jobs)}
    rescue
      e -> {:error, e}
    end
  end

  defp build_job(item) do
    priority = activity_priority(item.activity)

    %{
      "activity" => compact_activity(item.activity),
      "actor_uri" => item.actor_uri,
      "activity_id" => item.activity_id,
      "target_user_id" => item.target_user_id
    }
    |> Elektrine.ActivityPub.ProcessActivityWorker.new(priority: priority)
  end

  # Activity priority (same as ProcessActivityWorker)
  defp activity_priority(%{"type" => type} = activity) do
    case type do
      "Create" -> 0
      "Update" -> 0
      "Delete" -> 0
      "Follow" -> 1
      "Accept" -> 1
      "Reject" -> 1
      "Undo" -> 1
      "Block" -> 1
      "Like" -> 2
      "Dislike" -> 2
      "EmojiReact" -> 2
      "Announce" -> announce_priority(activity)
      _ -> 1
    end
  end

  defp announce_priority(%{"object" => object}) when is_map(object) do
    case object["type"] do
      type when type in ["Note", "Page", "Article", "Create", "Update", "Delete"] -> 0
      type when type in ["Like", "Dislike", "EmojiReact"] -> 2
      _ -> 1
    end
  end

  defp announce_priority(_), do: 1

  defp actor_domain(nil), do: "unknown"

  defp actor_domain(actor_uri) when is_binary(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "unknown"
    end
  end

  defp actor_domain(_), do: "unknown"

  defp overload_drop?(activity) do
    queue_size =
      case :ets.whereis(@table_name) do
        :undefined -> 0
        _ -> :ets.info(@table_name, :size) || 0
      end

    queue_size >= @max_queue_size and low_priority_activity?(activity)
  end

  defp low_priority_activity?(%{"type" => type}) when type in ["Like", "Dislike", "EmojiReact"] do
    true
  end

  defp low_priority_activity?(%{"type" => "Undo", "object" => %{"type" => object_type}})
       when object_type in ["Like", "Dislike", "EmojiReact"] do
    true
  end

  defp low_priority_activity?(_), do: false

  defp compact_activity(activity), do: drop_activity_keys(activity)

  defp drop_activity_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      if key in @activity_drop_keys do
        acc
      else
        Map.put(acc, key, drop_activity_keys(nested))
      end
    end)
  end

  defp drop_activity_keys(value) when is_list(value) do
    Enum.map(value, &drop_activity_keys/1)
  end

  defp drop_activity_keys(value), do: value

  # Deduplication helpers

  defp already_queued?(activity_id) do
    case :ets.lookup(:inbox_dedup, activity_id) do
      [{^activity_id, timestamp}] ->
        # Check if within dedup window (60 seconds)
        System.system_time(:second) - timestamp < 60

      _ ->
        false
    end
  end

  defp mark_queued(activity_id) do
    :ets.insert(:inbox_dedup, {activity_id, System.system_time(:second)})
  end

  defp cleanup_dedup do
    # 1% chance to clean up
    if :rand.uniform(100) == 1 do
      cutoff = System.system_time(:second) - 120

      try do
        :ets.select_delete(:inbox_dedup, [
          {{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
        ])
      rescue
        _ -> :ok
      end
    end
  end
end
