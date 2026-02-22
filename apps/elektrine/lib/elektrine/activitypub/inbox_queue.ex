defmodule Elektrine.ActivityPub.InboxQueue do
  @moduledoc "Fast in-memory queue for incoming ActivityPub activities.\n\nInstead of calling Oban.insert() for every /inbox request (which requires\na database connection), activities are queued in ETS and batch-inserted\ninto Oban periodically. This removes the database from the /inbox hot path.\n\nPerformance improvement: ~1000ms → ~5ms per /inbox request\n"
  use GenServer
  require Logger
  alias Elektrine.Telemetry.Events
  @table_name :inbox_activity_queue
  @flush_interval 500
  @max_batch_size 25
  @insert_chunk_size 5
  @max_queue_size 5000
  @activity_drop_keys ["contentMap"]
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueue an activity for processing. Returns immediately without hitting the database.\n"
  def enqueue(activity, actor_uri, target_user_id) do
    activity_id = activity["id"]
    activity_type = activity["type"] || "unknown"

    cond do
      activity_id && already_queued?(activity_id) ->
        Events.federation(:inbox_queue, :enqueue, :duplicate, nil, %{activity_type: activity_type})

        {:ok, :duplicate}

      overload_drop?(activity) ->
        Events.federation(:inbox_queue, :enqueue, :shed, nil, %{
          activity_type: activity_type,
          actor_domain: actor_domain(actor_uri)
        })

        {:ok, :shed}

      true ->
        if activity_id do
          mark_queued(activity_id)
        end

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

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set, write_concurrency: true])
    :ets.new(:inbox_dedup, [:named_table, :public, :set, write_concurrency: true])
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
    items = take_batch(@max_batch_size)

    if items != [] do
      flush_started_at = System.monotonic_time(:millisecond)
      flush_result = insert_in_chunks(items)
      flush_duration = System.monotonic_time(:millisecond) - flush_started_at

      case flush_result do
        {:ok, inserted_count} ->
          Logger.debug("InboxQueue flushed #{inserted_count} activities")

          Events.federation(:inbox_queue, :flush, :success, flush_duration, %{
            batch_size: inserted_count
          })

        {:error, reason, inserted_count, failed_items} ->
          Logger.error(
            "InboxQueue flush failed after #{inserted_count} inserts: #{inspect(reason)}"
          )

          Events.federation(:inbox_queue, :flush, :failure, flush_duration, %{
            batch_size: length(items),
            inserted_count: inserted_count,
            requeued_count: length(failed_items),
            reason: inspect(reason)
          })

          Enum.each(failed_items, fn item -> :ets.insert(@table_name, {make_ref(), item}) end)
      end

      cleanup_dedup()
    end
  end

  defp take_batch(limit) when is_integer(limit) and limit > 0 do
    do_take_batch(limit, :ets.first(@table_name), [])
  end

  defp take_batch(_) do
    []
  end

  defp do_take_batch(0, _key, acc) do
    Enum.reverse(acc)
  end

  defp do_take_batch(_remaining, :"$end_of_table", acc) do
    Enum.reverse(acc)
  end

  defp do_take_batch(remaining, key, acc) do
    next_key = :ets.next(@table_name, key)

    case :ets.take(@table_name, key) do
      [{^key, item}] -> do_take_batch(remaining - 1, next_key, [item | acc])
      [] -> do_take_batch(remaining, next_key, acc)
    end
  end

  defp insert_in_chunks(items) when is_list(items) do
    chunks = Enum.chunk_every(items, @insert_chunk_size)
    do_insert_chunks(chunks, 0)
  end

  defp do_insert_chunks([], inserted_count) do
    {:ok, inserted_count}
  end

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
    {:ok, Oban.insert_all(jobs)}
  rescue
    e -> {:error, e}
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

  defp announce_priority(_) do
    1
  end

  defp actor_domain(nil) do
    "unknown"
  end

  defp actor_domain(actor_uri) when is_binary(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "unknown"
    end
  end

  defp actor_domain(_) do
    "unknown"
  end

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

  defp low_priority_activity?(_) do
    false
  end

  defp compact_activity(activity) do
    drop_activity_keys(activity)
  end

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

  defp drop_activity_keys(value) do
    value
  end

  defp already_queued?(activity_id) do
    case :ets.lookup(:inbox_dedup, activity_id) do
      [{^activity_id, timestamp}] -> System.system_time(:second) - timestamp < 60
      _ -> false
    end
  end

  defp mark_queued(activity_id) do
    :ets.insert(:inbox_dedup, {activity_id, System.system_time(:second)})
  end

  defp cleanup_dedup do
    if :rand.uniform(100) == 1 do
      cutoff = System.system_time(:second) - 120

      try do
        :ets.select_delete(:inbox_dedup, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
      rescue
        _ -> :ok
      end
    end
  end
end
