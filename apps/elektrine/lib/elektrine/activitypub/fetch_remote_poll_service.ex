defmodule Elektrine.ActivityPub.FetchRemotePollService do
  @moduledoc """
  Refreshes a remote ActivityPub poll and syncs its local cached poll record.
  """

  require Logger

  alias Elektrine.ActivityPub.Fetcher
  alias Elektrine.ActivityPub.Handlers.{CreateHandler, UpdateHandler}
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  def call(%{id: _poll_id, message_id: _message_id} = poll) do
    poll = Repo.preload(poll, message: [:remote_actor])

    with %Message{} = message <- poll.message,
         true <- message.federated,
         true <- poll_stale?(poll),
         activitypub_id when is_binary(activitypub_id) <- message.activitypub_id,
         actor_uri when is_binary(actor_uri) <- message.remote_actor && message.remote_actor.uri,
         {:ok, object} when is_map(object) <- Fetcher.fetch_object(activitypub_id),
         {:ok, _} <- UpdateHandler.handle(%{"object" => object}, actor_uri, nil),
         {:ok, refreshed_poll} <- CreateHandler.upsert_federated_poll(message.id, object) do
      refreshed_poll
      |> Ecto.Changeset.change(last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update()
    else
      false ->
        {:ok, poll}

      nil ->
        {:error, :poll_not_refreshable}

      {:error, reason} ->
        {:error, reason}

      other ->
        Logger.warning("Failed to refresh remote poll #{poll.id}: #{inspect(other)}")
        {:error, :refresh_failed}
    end
  end

  def call(_), do: {:error, :invalid_poll}

  defp poll_stale?(%{last_fetched_at: last_fetched_at, closes_at: closes_at}) do
    expires_after_last_fetch? =
      is_nil(closes_at) || is_nil(last_fetched_at) ||
        DateTime.compare(last_fetched_at, closes_at) == :lt

    stale_fetch? =
      is_nil(last_fetched_at) ||
        DateTime.compare(last_fetched_at, DateTime.add(DateTime.utc_now(), -60, :second)) == :lt

    expires_after_last_fetch? && stale_fetch?
  end

  defp poll_stale?(_poll), do: true
end
