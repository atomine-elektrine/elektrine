defmodule ElektrineWeb.Presence do
  @moduledoc """
  Provides presence tracking to channels and processes.

  Per-device presences are tracked on the `PubSubTopics.users_presence/0`
  topic. The `handle_metas/4` callback aggregates them into one snapshot per
  user (best status across devices, device list, last-seen), kept in a
  node-local ETS table.

  Whenever a user's aggregate snapshot changes, `{:presence_changed, user_id,
  snapshot}` is broadcast node-locally on `PubSubTopics.users_presence_updates/0`.
  Raw per-device joins/leaves that don't change the visible snapshot broadcast
  nothing, so subscribers see rare status transitions instead of every diff.

  Status transitions also trigger side effects exactly once per node: the
  last-seen timestamp is persisted when a user's final device leaves, and the
  new status is published to federation peers. On a multi-node cluster these
  run on each node observing the transition; both are idempotent.

  Channel topics (calls, voice, mobile) also track through this module and are
  passed through untouched.

  See the [`Phoenix.Presence`](https://hexdocs.pm/phoenix/Phoenix.Presence.html)
  docs for more details.
  """
  use Phoenix.Presence,
    otp_app: :elektrine,
    pubsub_server: Elektrine.PubSub

  alias Elektrine.PubSubTopics

  @table :elektrine_user_presence_statuses

  ## Public API

  @doc """
  Subscribes the caller to aggregated `{:presence_changed, user_id, snapshot}`
  events.
  """
  def subscribe_status_updates do
    Phoenix.PubSub.subscribe(Elektrine.PubSub, PubSubTopics.users_presence_updates())
  end

  @doc """
  Tracks a user's device on the global presence topic.
  """
  def track_user(pid, user, device_info \\ %{}) do
    track(pid, PubSubTopics.users_presence(), to_string(user.id), %{
      user_id: user.id,
      username: user.username,
      status: user.status || "online",
      status_message: user.status_message,
      online_at: System.system_time(:second),
      last_seen_at:
        (user.last_seen_at && DateTime.to_unix(user.last_seen_at)) ||
          System.system_time(:second),
      device_type: device_info[:device_type] || "desktop",
      browser: device_info[:browser],
      timezone: device_info[:timezone],
      auto_away: false
    })
  end

  @doc """
  Merges `attrs` into the caller's presence meta on the global topic.
  """
  def update_user_meta(pid, user_id, attrs) when is_map(attrs) do
    update(pid, PubSubTopics.users_presence(), to_string(user_id), &Map.merge(&1, attrs))
  end

  @doc """
  Returns the aggregated status snapshots for all users this node has seen,
  as a map of string user id => snapshot.
  """
  def list_user_statuses do
    @table |> :ets.tab2list() |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  @doc """
  Returns the aggregated snapshot for one user, or an offline default.
  """
  def get_user_status(user_id) do
    case :ets.lookup(@table, to_string(user_id)) do
      [{_id, snapshot}] -> snapshot
      [] -> offline_snapshot(nil)
    end
  rescue
    ArgumentError -> offline_snapshot(nil)
  end

  ## Phoenix.Presence callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{users_topic: PubSubTopics.users_presence()}}
  end

  @impl true
  def handle_metas(topic, %{joins: joins, leaves: leaves}, presences, state) do
    if topic == state.users_topic do
      (Map.keys(joins) ++ Map.keys(leaves))
      |> Enum.uniq()
      |> Enum.each(fn user_id ->
        refresh_user(user_id, Map.get(presences, user_id, []))
      end)
    end

    {:ok, state}
  end

  defp refresh_user(user_id, metas) do
    prev =
      case :ets.lookup(@table, user_id) do
        [{_id, snapshot}] -> snapshot
        [] -> nil
      end

    snapshot =
      case metas do
        [] -> offline_snapshot(prev)
        metas -> aggregate_metas(metas)
      end

    if snapshot != prev do
      :ets.insert(@table, {user_id, snapshot})

      Phoenix.PubSub.local_broadcast(
        Elektrine.PubSub,
        PubSubTopics.users_presence_updates(),
        {:presence_changed, user_id, snapshot}
      )

      if is_nil(prev) or prev.status != snapshot.status do
        publish_side_effects(user_id, snapshot.status)
      end
    end
  end

  # Persist last-seen and notify federation peers off the tracker process.
  # Async.start keeps DB/network work out of the tracker shard and skips it
  # entirely under the test sandbox.
  defp publish_side_effects(user_id, status) do
    with {db_user_id, ""} when db_user_id > 0 <- Integer.parse(user_id) do
      Elektrine.Async.start(fn ->
        if status == "offline" do
          Elektrine.Accounts.update_last_seen_async(db_user_id)
        end

        Elektrine.Messaging.Federation.publish_user_presence_update(
          db_user_id,
          federation_status(status),
          []
        )
      end)
    end
  end

  # ARBP presence vocabulary is online/idle/dnd/offline/invisible.
  defp federation_status("away"), do: "idle"
  defp federation_status(status) when status in ~w(online idle dnd offline invisible), do: status
  defp federation_status(_status), do: "online"

  defp aggregate_metas(metas) do
    devices =
      metas
      |> Enum.map(fn meta -> meta[:device_type] || "desktop" end)
      |> Enum.uniq()

    status =
      metas
      |> Enum.map(fn meta -> meta[:status] || "online" end)
      |> Enum.min_by(&status_priority/1)

    message = Enum.find_value(metas, fn meta -> meta[:status_message] end)

    last_seen =
      metas
      |> Enum.map(fn meta -> meta[:last_seen_at] || meta[:online_at] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> System.system_time(:second) end)

    %{
      status: status,
      message: message,
      last_seen_at: last_seen,
      devices: devices,
      device_count: length(metas)
    }
  end

  defp offline_snapshot(prev) do
    %{
      status: "offline",
      message: prev && prev.message,
      last_seen_at: System.system_time(:second),
      devices: [],
      device_count: 0
    }
  end

  @doc """
  Status priority for cross-device aggregation (lower = more present).
  """
  def status_priority("online"), do: 1
  def status_priority("away"), do: 2
  def status_priority("dnd"), do: 3
  def status_priority("offline"), do: 4
  def status_priority(_), do: 5
end
