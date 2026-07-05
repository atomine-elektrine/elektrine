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
    unique: [
      period: 300,
      keys: [:message_id, :force],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Elektrine.ActivityPub.{FederationLoadGuard, Helpers, RepliesFetcher}
  alias Elektrine.Messaging

  @max_ancestor_depth 10

  def enqueue(message_id, opts \\ [])

  def enqueue(message_id, opts) when is_integer(message_id) and message_id > 0 do
    %{"message_id" => message_id, "force" => Keyword.get(opts, :force, false)}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue(_, _opts), do: {:error, :invalid_message_id}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id} = args}) do
    # A forced backfill is a direct user action (retry button), so it bypasses
    # the load shed and the reply-fetch cooldown.
    force = args["force"] == true

    if not force and FederationLoadGuard.skip_nonessential?(__MODULE__) do
      {:discard, :federation_overloaded}
    else
      case Messaging.get_message(message_id) do
        nil ->
          {:discard, :message_not_found}

        message ->
          actor_uri = message.remote_actor && message.remote_actor.uri
          :ok = backfill_ancestors(message, actor_uri, 0)

          case RepliesFetcher.fetch_full_thread_for_message(message.id,
                 skip_cache: true,
                 skip_cooldown: force
               ) do
            {:ok, _} -> :ok
            {:error, :message_not_found} -> {:discard, :message_not_found}
            {:error, :no_activitypub_id} -> {:discard, :no_activitypub_id}
            {:error, reason} -> {:error, reason}
          end
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
    cond do
      not (is_nil(message.reply_to_id) && is_integer(parent.id)) ->
        :ok

      # Guard against self-reference and direct 2-cycles.
      parent.id == message.id or parent.reply_to_id == message.id ->
        :ok

      true ->
        case message
             |> Ecto.Changeset.change(reply_to_id: parent.id)
             |> Elektrine.Repo.update() do
          {:ok, _updated} ->
            Elektrine.ActivityPub.SideEffects.increment_reply_count(parent.id)
            :ok

          error ->
            error
        end
    end
  end
end
