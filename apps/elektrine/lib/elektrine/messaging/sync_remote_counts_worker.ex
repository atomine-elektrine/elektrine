defmodule Elektrine.Messaging.SyncRemoteCountsWorker do
  @moduledoc """
  Persists freshly fetched remote count data through Oban so LiveViews don't
  spawn ad hoc tasks for metadata sync.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 2,
    unique: [period: 60, keys: [:activitypub_id], states: [:available, :scheduled, :executing]]

  alias Elektrine.ActivityPub.RefreshCountsWorker
  alias Elektrine.Messaging

  def enqueue(post_object) when is_map(post_object) do
    activitypub_id = post_object["id"] || post_object["url"]

    %{"activitypub_id" => activitypub_id}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue(_post_object), do: {:error, :invalid_post_object}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activitypub_id" => activitypub_id}})
      when is_binary(activitypub_id) do
    refresh_cached_message_counts(activitypub_id)
    :ok
  end

  def perform(%Oban.Job{args: %{"post_object" => post_object}}) when is_map(post_object) do
    refresh_cached_message_counts(post_object["id"] || post_object["url"])
    :ok
  end

  defp refresh_cached_message_counts(activitypub_ref) when is_binary(activitypub_ref) do
    case Messaging.get_message_by_activitypub_ref(activitypub_ref) do
      %{id: message_id} when is_integer(message_id) ->
        _ = RefreshCountsWorker.refresh_now(message_id)
        :ok

      _ ->
        :ok
    end
  end

  defp refresh_cached_message_counts(_), do: :ok
end
