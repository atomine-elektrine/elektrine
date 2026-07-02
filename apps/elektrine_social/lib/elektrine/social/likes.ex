defmodule Elektrine.Social.Likes do
  @moduledoc """
  Handles post likes and related operations.

  This module manages the like system for posts, including:
  - Creating and removing likes
  - Counting likes
  - Checking like status
  - Broadcasting like events via PubSub
  - Federating likes via ActivityPub
  """

  import Ecto.Query, warn: false
  require Logger
  alias Elektrine.AppCache
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.MessagePolicy
  alias Elektrine.Social.MessageStats
  alias Elektrine.Social.PostLike

  @doc """
  Likes a post.

  This function:
  1. Creates a like record
  2. Increments the like count on the message
  3. Broadcasts the like event via PubSub (async)
  4. Creates a notification for the post author (async)
  5. Federates the like via ActivityPub (async)

  Returns `{:ok, like}` on success. Already-liked posts return the existing like.
  """
  def like_post(user_id, message_id) do
    message = get_message!(message_id)

    if MessagePolicy.like?(user_id, message) do
      case Repo.get_by(PostLike, user_id: user_id, message_id: message_id) do
        %PostLike{} = like ->
          {:ok, like}

        nil ->
          insert_like(user_id, message_id, message)
      end
    else
      {:error, :not_authorized}
    end
  end

  defp insert_like(user_id, message_id, message) do
    now = DateTime.utc_now()

    %PostLike{}
    |> PostLike.changeset(%{
      user_id: user_id,
      message_id: message_id,
      created_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, like} ->
        reconcile_like_count(message, 1)

        # Broadcast engagement updates synchronously so rapid toggles stay ordered for the UI.
        safe_broadcast_like_event(:liked, like)

        # Keep slower side effects async.
        Elektrine.Async.run(fn ->
          # Only notify for local posts with sender_id
          message = get_message!(message_id)

          if message.sender_id do
            notify_post_like(user_id, message_id)
          end

          # Federate the like to ActivityPub
          Elektrine.ActivityPub.Outbox.federate_like(message_id, user_id)
          # Queue durable Bluesky like sync
          _ = Elektrine.Bluesky.OutboundWorker.enqueue_like(message_id, user_id)
        end)

        {:ok, like}

      {:error, _} = error ->
        case Repo.get_by(PostLike, user_id: user_id, message_id: message_id) do
          %PostLike{} = like -> {:ok, like}
          nil -> error
        end
    end
  end

  @doc """
  Unlikes a post.

  Returns `{:ok, deleted_like}` on success. Already-unliked posts return `{:ok, nil}`.
  """
  def unlike_post(user_id, message_id) do
    message = get_message!(message_id)

    case Repo.get_by(PostLike, user_id: user_id, message_id: message_id) do
      nil ->
        {:ok, nil}

      like ->
        case Repo.delete(like) do
          {:ok, deleted_like} ->
            reconcile_like_count(message, -1)

            # Broadcast engagement updates synchronously so rapid toggles stay ordered for the UI.
            safe_broadcast_like_event(:unliked, deleted_like)

            # Keep slower side effects async.
            Elektrine.Async.run(fn ->
              # Federate the unlike to ActivityPub
              Elektrine.ActivityPub.Outbox.federate_unlike(message_id, user_id)
              # Queue durable Bluesky unlike sync
              _ = Elektrine.Bluesky.OutboundWorker.enqueue_unlike(message_id, user_id)
            end)

            {:ok, deleted_like}

          error ->
            error
        end
    end
  end

  @doc """
  Checks if user has liked a post.
  """
  def user_liked_post?(user_id, message_id) do
    Repo.exists?(
      from l in PostLike,
        where: l.user_id == ^user_id and l.message_id == ^message_id
    )
  end

  @doc """
  Returns a list of message IDs that the user has liked from the given list.

  Useful for efficiently checking multiple posts at once.
  """
  def list_user_likes(user_id, message_ids) when is_list(message_ids) do
    from(l in PostLike,
      where: l.user_id == ^user_id and l.message_id in ^message_ids,
      select: l.message_id
    )
    |> Repo.all()
  end

  @doc """
  Gets statuses liked by a user, newest like first.
  """
  def get_liked_posts(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    search_query = Keyword.get(opts, :search_query)
    before_id = Keyword.get(opts, :before_id)
    since_id = Keyword.get(opts, :since_id)
    min_id = Keyword.get(opts, :min_id)
    viewer_id = Keyword.get(opts, :viewer_id, user_id)
    candidate_limit = max(limit * 5, 100)

    liked_ids_query =
      from(l in PostLike,
        where: l.user_id == ^user_id,
        join: m in Message,
        on: m.id == l.message_id,
        left_join: sender in assoc(m, :sender),
        left_join: remote_actor in assoc(m, :remote_actor),
        where: is_nil(m.deleted_at),
        order_by: [desc: l.created_at, desc: l.id],
        limit: ^candidate_limit,
        offset: ^offset,
        select: {m.id, l.created_at}
      )

    liked_ids_query =
      liked_ids_query
      |> maybe_filter_before_id(before_id)
      |> maybe_filter_since_id(since_id)
      |> maybe_filter_since_id(min_id)
      |> maybe_filter_search(search_query)

    id_order_pairs = Repo.all(liked_ids_query)
    message_ids = Enum.map(id_order_pairs, fn {id, _} -> id end)

    if message_ids == [] do
      []
    else
      messages =
        from(m in Message,
          where: m.id in ^message_ids,
          preload: [
            sender: [:profile],
            conversation: [],
            link_preview: [],
            hashtags: [],
            remote_actor: []
          ]
        )
        |> Repo.all()

      id_to_order =
        id_order_pairs
        |> Enum.with_index()
        |> Enum.into(%{}, fn {{id, _}, idx} -> {id, idx} end)

      messages
      |> Enum.sort_by(fn message -> Map.get(id_to_order, message.id, 999_999) end)
      |> Enum.filter(&MessagePolicy.visible?(viewer_id, &1))
      |> Enum.take(limit)
    end
  end

  # Private functions

  defp maybe_filter_before_id(query, id) when is_integer(id) do
    from([_like, message, _sender, _remote_actor] in query, where: message.id < ^id)
  end

  defp maybe_filter_before_id(query, _id), do: query

  defp maybe_filter_since_id(query, id) when is_integer(id) do
    from([_like, message, _sender, _remote_actor] in query, where: message.id > ^id)
  end

  defp maybe_filter_since_id(query, _id), do: query

  defp maybe_filter_search(query, search_query) do
    if Elektrine.Strings.present?(search_query) do
      pattern = "%" <> search_query <> "%"

      from([_like, message, sender, remote_actor] in query,
        where:
          ilike(message.content, ^pattern) or
            (not is_nil(message.title) and ilike(message.title, ^pattern)) or
            (not is_nil(sender.username) and ilike(sender.username, ^pattern)) or
            (not is_nil(sender.display_name) and ilike(sender.display_name, ^pattern)) or
            (not is_nil(remote_actor.username) and ilike(remote_actor.username, ^pattern)) or
            (not is_nil(remote_actor.display_name) and ilike(remote_actor.display_name, ^pattern)) or
            (not is_nil(remote_actor.domain) and ilike(remote_actor.domain, ^pattern))
      )
    else
      query
    end
  end

  defp reconcile_like_count(%Message{} = message, delta) when delta in [-1, 1] do
    message = Repo.get!(Message, message.id)

    current_local_like_count =
      from(l in PostLike,
        where: l.message_id == ^message.id,
        select: count(l.id)
      )
      |> Repo.one()

    previous_local_like_count = max(current_local_like_count - delta, 0)

    remote_baseline =
      message
      |> remote_like_count_baseline()
      |> max(max((message.like_count || 0) - previous_local_like_count, 0))

    like_count = remote_baseline + current_local_like_count

    result =
      from(m in Message,
        where: m.id == ^message.id,
        update: [set: [like_count: ^like_count]]
      )
      |> Repo.update_all([])

    AppCache.invalidate_social_message(message.id)
    MessageStats.upsert_counts(message.id, %{like_count: like_count})
    result
  end

  defp remote_like_count_baseline(%Message{} = message) do
    remote_count =
      message
      |> Map.get(:remote_like_count)
      |> parse_non_negative_integer()

    metadata_count =
      message
      |> Map.get(:media_metadata, %{})
      |> Map.get("original_like_count")
      |> parse_non_negative_integer()

    max(remote_count, metadata_count)
  end

  defp parse_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count >= 0 -> count
      _ -> 0
    end
  end

  defp parse_non_negative_integer(_), do: 0

  defp safe_broadcast_like_event(event_type, like) do
    broadcast_like_event(event_type, like)
  rescue
    error ->
      Logger.warning(
        "Failed to broadcast like event #{inspect(event_type)}: #{Exception.message(error)}"
      )

      :ok
  end

  defp broadcast_like_event(event_type, like) do
    like = Repo.preload(like, [:message, :user])

    # Broadcast to specific message
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "message:#{like.message_id}",
      {event_type, like}
    )

    message =
      get_message!(like.message_id)
      |> Repo.preload([:conversation, :hashtags])

    payload = %{
      message_id: like.message_id,
      like_count: message.like_count,
      sender_id: message.sender_id,
      remote_actor_id: message.remote_actor_id,
      creator_id: message.sender_id || message.remote_actor_id,
      creator_type:
        if(message.federated || not is_nil(message.remote_actor_id), do: "remote", else: "local"),
      hashtags: Enum.map(message.hashtags || [], & &1.normalized_name)
    }

    Elektrine.Social.Messages.broadcast_post_counts_updated(like.message_id, %{
      like_count: message.like_count || 0,
      share_count: message.share_count || 0,
      reply_count: message.reply_count || 0
    })

    # Broadcast to timeline feeds if it's a timeline post OR federated post
    # Always use :post_liked event type (whether liking or unliking) for consistency
    if (message.conversation && message.conversation.type == "timeline") || message.federated do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "timeline:all",
        {:post_liked, payload}
      )
    end

    # Broadcast to discussion feeds if it's a discussion post
    if message.conversation && message.conversation.type == "community" do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "discussion:#{message.conversation_id}",
        {:post_liked, payload}
      )
    end
  end

  # Notifies post owner when their post is liked
  defp notify_post_like(liker_id, message_id) do
    # Get the post and users
    message = get_message!(message_id)

    # Don't notify if user liked their own post
    # Only notify for local posts (federated posts don't have sender_id)
    if message.sender_id && liker_id != message.sender_id do
      # Check if user wants to be notified about likes
      user = Elektrine.Accounts.get_user!(message.sender_id)

      if Map.get(user, :notify_on_like, true) do
        liker = Elektrine.Accounts.get_user!(liker_id)

        Elektrine.Notifications.create_notification(%{
          user_id: message.sender_id,
          actor_id: liker_id,
          type: "like",
          title: "@#{liker.handle || liker.username} liked your post",
          url: Elektrine.Paths.post_path(message_id),
          source_type: "message",
          source_id: message_id,
          priority: "low"
        })
      end
    end
  end

  defp get_message!(message_id) do
    case AppCache.get_social_message(message_id, fn -> Repo.get(Message, message_id) end) do
      %Message{} = message -> message
      _ -> Repo.get!(Message, message_id)
    end
  end
end
