defmodule ElektrineWeb.Live.Helpers.PostStateHelpers do
  @moduledoc """
  Shared helpers for managing post interaction state (likes, boosts, follows) across LiveViews.
  Eliminates duplication across Timeline, Hashtag, List, Overview, and Gallery views.
  """

  import Ecto.Query
  require Logger

  alias Elektrine.Messaging.MessageReaction
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.{PostBoost, PostLike}
  alias Elektrine.Social.SavedItem

  @doc """
  Gets a map of message_id => is_liked for the given user and posts.
  Performs a single batch query for efficiency.
  Handles both list of post structs and list of message IDs.
  """
  def get_user_likes(user_id, posts) when is_list(posts) do
    # Handle both post structs and raw IDs
    message_ids =
      posts
      |> Enum.map(fn
        # Post struct
        %{id: id} -> id
        # Raw ID
        id when is_integer(id) -> id
      end)
      |> Enum.uniq()

    if Enum.empty?(message_ids) do
      %{}
    else
      # Batch query to check all likes at once
      liked_ids =
        from(l in PostLike,
          where: l.user_id == ^user_id and l.message_id in ^message_ids,
          select: l.message_id
        )
        |> Repo.all()

      # Build map of message_id => is_liked
      Enum.reduce(message_ids, %{}, fn message_id, acc ->
        Map.put(acc, message_id, message_id in liked_ids)
      end)
    end
  end

  @doc """
  Gets a map of message_id => is_boosted for the given user and posts.
  Handles both list of post structs and list of message IDs.
  """
  def get_user_boosts(user_id, posts) when is_list(posts) do
    # Handle both post structs and raw IDs
    message_ids =
      posts
      |> Enum.map(fn
        # Post struct
        %{id: id} -> id
        # Raw ID
        id when is_integer(id) -> id
      end)
      |> Enum.uniq()

    if Enum.empty?(message_ids) do
      %{}
    else
      # Batch query to check all boosts at once
      boosted_ids =
        from(b in PostBoost,
          where: b.user_id == ^user_id and b.message_id in ^message_ids,
          select: b.message_id
        )
        |> Repo.all()

      # Build map of message_id => is_boosted
      Enum.reduce(message_ids, %{}, fn message_id, acc ->
        Map.put(acc, message_id, message_id in boosted_ids)
      end)
    end
  end

  @doc """
  Gets follow state for posts (both local and remote actors).
  Returns a map of {:local, user_id} or {:remote, actor_id} => is_following.
  Only works with post structs (not raw IDs).
  """
  def get_user_follows(user_id, posts) when is_list(posts) do
    # Extract local user IDs and remote actor IDs from posts
    # Filter out non-struct items
    post_structs = Enum.filter(posts, &is_map/1)

    user_ids =
      post_structs
      |> Enum.map(fn post -> Map.get(post, :sender_id) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    remote_actor_ids =
      post_structs
      |> Enum.map(fn post -> Map.get(post, :remote_actor_id) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Query local follows
    local_follows =
      if Enum.empty?(user_ids) do
        []
      else
        from(f in Follow,
          where: f.follower_id == ^user_id and f.followed_id in ^user_ids,
          select: {:local, f.followed_id}
        )
        |> Repo.all()
      end

    # Query remote follows (only accepted, not pending)
    remote_follows =
      if Enum.empty?(remote_actor_ids) do
        []
      else
        from(f in Follow,
          where:
            f.follower_id == ^user_id and f.remote_actor_id in ^remote_actor_ids and
              is_nil(f.followed_id) and f.pending == false,
          select: {:remote, f.remote_actor_id}
        )
        |> Repo.all()
      end

    # Build combined map
    all_follows = local_follows ++ remote_follows

    Enum.reduce(all_follows, %{}, fn
      {:local, id}, acc -> Map.put(acc, {:local, id}, true)
      {:remote, id}, acc -> Map.put(acc, {:remote, id}, true)
    end)
  end

  @doc """
  Gets pending follow state for remote actors.
  Returns a map of {:remote, actor_id} => is_pending.
  Only works with post structs (not raw IDs).
  """
  def get_pending_follows(user_id, posts) when is_list(posts) do
    # Get remote actor IDs from posts
    # Filter out non-struct items
    post_structs = Enum.filter(posts, &is_map/1)

    remote_actor_ids =
      post_structs
      |> Enum.map(fn post -> Map.get(post, :remote_actor_id) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Query pending remote follows
    pending_follows =
      if Enum.empty?(remote_actor_ids) do
        []
      else
        from(f in Follow,
          where:
            f.follower_id == ^user_id and f.remote_actor_id in ^remote_actor_ids and
              is_nil(f.followed_id) and f.pending == true,
          select: {:remote, f.remote_actor_id}
        )
        |> Repo.all()
      end

    Logger.debug("Found #{length(pending_follows)} pending remote follows")

    # Build map
    Enum.reduce(pending_follows, %{}, fn {:remote, id}, acc ->
      Map.put(acc, {:remote, id}, true)
    end)
  end

  @doc """
  Updates post counts (like_count, reply_count, share_count) in socket assigns.
  Useful for optimistic updates after interactions.
  """
  def update_post_count(socket, message_id, count_field, increment) do
    # Score fields can go negative, count fields stay at 0 minimum
    allow_negative = count_field in [:score, :dislike_count, :downvotes]

    update_fn = fn posts ->
      Enum.map(posts, fn post ->
        cond do
          # Update the original post's count
          post.id == message_id ->
            current_count = Map.get(post, count_field, 0) || 0
            new_count = current_count + increment
            Map.put(post, count_field, if(allow_negative, do: new_count, else: max(0, new_count)))

          # Update shared_message count if this post shares the target (and association is loaded)
          Ecto.assoc_loaded?(post.shared_message) && post.shared_message &&
              post.shared_message.id == message_id ->
            shared = post.shared_message
            current_count = Map.get(shared, count_field, 0) || 0
            new_count = current_count + increment

            updated_shared =
              Map.put(
                shared,
                count_field,
                if(allow_negative, do: new_count, else: max(0, new_count))
              )

            Map.put(post, :shared_message, updated_shared)

          # No change
          true ->
            post
        end
      end)
    end

    # Update timeline_posts if it exists
    socket =
      if Map.has_key?(socket.assigns, :timeline_posts) do
        Phoenix.Component.update(socket, :timeline_posts, update_fn)
      else
        socket
      end

    # Also update filtered_posts if it exists (for timeline filtering)
    socket =
      if Map.has_key?(socket.assigns, :filtered_posts) do
        Phoenix.Component.update(socket, :filtered_posts, update_fn)
      else
        socket
      end

    # Also update post_replies if it exists (for replies in timeline)
    socket =
      if Map.has_key?(socket.assigns, :post_replies) do
        Phoenix.Component.update(socket, :post_replies, fn replies_map ->
          Map.new(replies_map, fn {post_id, replies} ->
            updated_replies =
              Enum.map(replies, fn reply ->
                if reply.id == message_id do
                  current_count = Map.get(reply, count_field, 0)
                  Map.put(reply, count_field, max(0, current_count + increment))
                else
                  reply
                end
              end)

            {post_id, updated_replies}
          end)
        end)
      else
        socket
      end

    # Also update modal_post if it matches (for image modal like button)
    socket =
      if Map.has_key?(socket.assigns, :modal_post) && socket.assigns.modal_post &&
           socket.assigns.modal_post.id == message_id do
        modal_post = socket.assigns.modal_post
        current_count = Map.get(modal_post, count_field, 0) || 0
        new_count = current_count + increment

        updated_modal_post =
          Map.put(
            modal_post,
            count_field,
            if(allow_negative, do: new_count, else: max(0, new_count))
          )

        Phoenix.Component.assign(socket, :modal_post, updated_modal_post)
      else
        socket
      end

    socket
  end

  @doc """
  Gets reactions for a list of posts.
  Returns a map of message_id => list of reactions (with user/remote_actor preloaded).
  """
  def get_post_reactions(posts) when is_list(posts) do
    message_ids =
      posts
      |> Enum.map(fn
        %{id: id} -> id
        id when is_integer(id) -> id
      end)
      |> Enum.uniq()

    if Enum.empty?(message_ids) do
      %{}
    else
      # Batch query to get all reactions with users preloaded
      reactions =
        from(r in MessageReaction,
          where: r.message_id in ^message_ids,
          preload: [:user, :remote_actor],
          order_by: [asc: r.inserted_at]
        )
        |> Repo.all()

      # Group reactions by message_id
      Enum.group_by(reactions, & &1.message_id)
    end
  end

  def get_post_reactions(_), do: %{}

  @doc """
  Gets a map of message_id => is_saved for the given user and posts.
  Performs a single batch query for efficiency.
  """
  def get_user_saves(user_id, posts) when is_list(posts) do
    message_ids =
      posts
      |> Enum.map(fn
        %{id: id} -> id
        id when is_integer(id) -> id
      end)
      |> Enum.uniq()

    if Enum.empty?(message_ids) do
      %{}
    else
      saved_ids =
        from(s in SavedItem,
          where: s.user_id == ^user_id and s.message_id in ^message_ids,
          select: s.message_id
        )
        |> Repo.all()

      Enum.reduce(message_ids, %{}, fn message_id, acc ->
        Map.put(acc, message_id, message_id in saved_ids)
      end)
    end
  end
end
