defmodule Elektrine.ActivityPub.FetchRemotePollWorker do
  @moduledoc """
  Refreshes a cached remote poll through Oban so LiveViews don't perform
  network fetches inline.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 3,
    unique: [period: 60, keys: [:message_id], states: [:available, :scheduled, :executing]]

  alias Elektrine.ActivityPub.FetchRemotePollService
  alias Elektrine.Messaging
  alias Elektrine.Repo

  def enqueue(message_id) when is_integer(message_id) and message_id > 0 do
    %{"message_id" => message_id}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue(_message_id), do: {:error, :invalid_message_id}

  @impl Oban.Worker
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
end
