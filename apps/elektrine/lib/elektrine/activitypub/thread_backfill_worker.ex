defmodule Elektrine.ActivityPub.ThreadBackfillWorker do
  @moduledoc """
  Backfills a remote thread by storing missing ancestors and ingesting replies.

  This is closer to Mastodon's thread/context hydration model: when a remote
  post is opened, we try to ensure the local DB has both the ancestor chain and
  the descendant replies needed to render a coherent thread.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 2,
    unique: [period: 120, keys: [:message_id], states: [:available, :scheduled, :executing]]

  alias Elektrine.ActivityPub.Helpers
  alias Elektrine.ActivityPub.RepliesFetcher
  alias Elektrine.Messaging

  @max_ancestor_depth 10

  def enqueue(message_id) when is_integer(message_id) and message_id > 0 do
    %{"message_id" => message_id}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue(_), do: {:error, :invalid_message_id}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id}}) do
    case Messaging.get_message(message_id) do
      nil ->
        {:discard, :message_not_found}

      message ->
        actor_uri = message.remote_actor && message.remote_actor.uri
        :ok = backfill_ancestors(message, actor_uri, 0)

        case RepliesFetcher.fetch_replies_for_message(message.id) do
          {:ok, _} -> :ok
          {:error, :message_not_found} -> {:discard, :message_not_found}
          {:error, :no_activitypub_id} -> {:discard, :no_activitypub_id}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp backfill_ancestors(_message, _actor_uri, depth) when depth >= @max_ancestor_depth, do: :ok

  defp backfill_ancestors(message, actor_uri, depth) do
    metadata = message.media_metadata || %{}

    in_reply_to_ref =
      metadata["inReplyTo"] || metadata[:inReplyTo] || metadata["in_reply_to"] ||
        metadata[:in_reply_to]

    cond do
      message.reply_to_id ->
        case Messaging.get_message(message.reply_to_id) do
          nil -> :ok
          parent -> backfill_ancestors(parent, actor_uri, depth + 1)
        end

      !is_binary(in_reply_to_ref) or String.trim(in_reply_to_ref) == "" ->
        :ok

      parent = Messaging.get_message_by_activitypub_ref(String.trim(in_reply_to_ref)) ->
        maybe_link_reply_to_parent(message, parent)
        backfill_ancestors(parent, actor_uri, depth + 1)

      true ->
        case Helpers.get_or_store_remote_post(String.trim(in_reply_to_ref), actor_uri) do
          {:ok, parent} when is_map(parent) ->
            maybe_link_reply_to_parent(message, parent)
            backfill_ancestors(parent, actor_uri, depth + 1)

          _ ->
            :ok
        end
    end
  end

  defp maybe_link_reply_to_parent(message, parent) do
    if is_nil(message.reply_to_id) && is_integer(parent.id) do
      message
      |> Ecto.Changeset.change(reply_to_id: parent.id)
      |> Elektrine.Repo.update()
    else
      :ok
    end
  end
end
