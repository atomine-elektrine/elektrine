defmodule Elektrine.Messaging.SyncRemoteCountsWorker do
  @moduledoc """
  Persists freshly fetched remote count data through Oban so LiveViews don't
  spawn ad hoc tasks for metadata sync.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 2,
    unique: [period: 60, keys: [:activitypub_id], states: [:available, :scheduled, :executing]]

  alias Elektrine.Social.Messages

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
    Messages.sync_remote_counts(%{"id" => activitypub_id})
    :ok
  end

  def perform(%Oban.Job{args: %{"post_object" => post_object}}) when is_map(post_object) do
    sanitized_post_object = %{"id" => post_object["id"] || post_object["url"]}
    Messages.sync_remote_counts(sanitized_post_object)
    :ok
  end
end
