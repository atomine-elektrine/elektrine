defmodule Elektrine.ActivityPub.FetchRemotePollWorker do
  @moduledoc """
  Refreshes a cached remote poll through Oban so LiveViews don't perform
  network fetches inline.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:message_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  alias Elektrine.ActivityPub.FetchRemotePollService
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.Social.{Message, Poll}

  def enqueue(message_id) when is_integer(message_id) and message_id > 0 do
    %{"message_id" => message_id}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue(_message_id), do: {:error, :invalid_message_id}

  def enqueue_final_due(limit \\ 100) do
    %{"type" => "final_due", "limit" => limit}
    |> new(unique: [period: 3_600, keys: [:type]])
    |> Elektrine.JobQueue.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "final_due"} = args}) do
    args
    |> Map.get("limit", 100)
    |> enqueue_final_due_batch()

    :ok
  end

  def perform(%Oban.Job{args: %{"message_id" => message_id}}) do
    case message_id |> Messaging.get_message() |> Repo.preload(poll: [options: []]) do
      %{post_type: "poll", poll: poll} when not is_nil(poll) ->
        case FetchRemotePollService.call(poll) do
          {:ok, _poll} -> :ok
          {:error, :poll_not_refreshable} -> {:discard, :poll_not_refreshable}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:discard, :message_not_poll}
    end
  end

  defp enqueue_final_due_batch(limit) do
    limit = max(1, min(limit || 100, 500))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Poll
    |> join(:inner, [p], m in Message, on: m.id == p.message_id)
    |> where([p, m], m.federated == true)
    |> where([p, _m], not is_nil(p.closes_at) and p.closes_at <= ^now)
    |> where([p, _m], is_nil(p.last_fetched_at) or p.last_fetched_at < p.closes_at)
    |> order_by([p, _m], asc: p.closes_at)
    |> limit(^limit)
    |> select([p, _m], p.message_id)
    |> Repo.all()
    |> Enum.each(&enqueue/1)
  end
end
