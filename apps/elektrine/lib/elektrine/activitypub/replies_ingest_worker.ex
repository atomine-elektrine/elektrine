defmodule Elektrine.ActivityPub.RepliesIngestWorker do
  @moduledoc """
  Background worker for ingesting remote replies into local storage.

  Timeline reads stay local-first by enqueueing reply ingestion instead of
  issuing direct remote HTTP fetches in the LiveView read path.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 2,
    unique: [period: 300, keys: [:message_id], states: [:available, :scheduled, :executing]]

  alias Elektrine.ActivityPub.RepliesFetcher

  @doc """
  Enqueue a reply ingestion job for a local message id.
  """
  def enqueue(message_id) when is_integer(message_id) and message_id > 0 do
    %{"message_id" => message_id}
    |> new()
    |> Oban.insert()
  end

  def enqueue(_message_id), do: {:error, :invalid_message_id}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id}}) do
    case RepliesFetcher.fetch_replies_for_message(message_id) do
      {:ok, _count} -> :ok
      {:error, :message_not_found} -> {:discard, :message_not_found}
      {:error, :no_activitypub_id} -> {:discard, :no_activitypub_id}
      {:error, _reason} -> :ok
    end
  end
end
