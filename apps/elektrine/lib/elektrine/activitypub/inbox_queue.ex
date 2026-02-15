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
  @max_batch_size 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueue an activity for processing. Returns immediately without hitting the database.
  """
  def enqueue(activity, actor_uri, target_user_id) do
    activity_id = activity["id"]
    activity_type = activity["type"] || "unknown"

    # Fast dedup check
    if activity_id && already_queued?(activity_id) do
      Events.federation(:inbox_queue, :enqueue, :duplicate, nil, %{
        activity_type: activity_type
      })

      {:ok, :duplicate}
    else
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
    # Get all queued items (up to max batch size)
    items =
      :ets.tab2list(@table_name)
      |> Enum.take(@max_batch_size)

    if items != [] do
      flush_started_at = System.monotonic_time(:millisecond)

      # Delete the items we're processing
      Enum.each(items, fn {ref, _item} ->
        :ets.delete(@table_name, ref)
      end)

      # Build Oban jobs
      jobs =
        Enum.map(items, fn {_ref, item} ->
          priority = activity_priority(item.activity)

          %{
            "activity" => item.activity,
            "actor_uri" => item.actor_uri,
            "activity_id" => item.activity_id,
            "target_user_id" => item.target_user_id
          }
          |> Elektrine.ActivityPub.ProcessActivityWorker.new(priority: priority)
        end)

      # Batch insert into Oban (single DB transaction)
      try do
        inserted = Oban.insert_all(jobs)
        Logger.debug("InboxQueue flushed #{length(inserted)} activities")

        Events.federation(
          :inbox_queue,
          :flush,
          :success,
          System.monotonic_time(:millisecond) - flush_started_at,
          %{
            batch_size: length(inserted)
          }
        )
      rescue
        e ->
          Logger.error("InboxQueue flush failed: #{inspect(e)}")

          Events.federation(
            :inbox_queue,
            :flush,
            :failure,
            System.monotonic_time(:millisecond) - flush_started_at,
            %{
              batch_size: length(items),
              reason: inspect(e)
            }
          )

          # Re-queue failed items
          Enum.each(items, fn {_ref, item} ->
            :ets.insert(@table_name, {make_ref(), item})
          end)
      end

      # Clean up old dedup entries periodically
      cleanup_dedup()
    end
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
