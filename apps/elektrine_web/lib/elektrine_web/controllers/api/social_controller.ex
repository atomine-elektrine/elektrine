defmodule ElektrineWeb.API.SocialController do
  @moduledoc """
  API controller for social features: timeline, posts, likes, boosts, comments.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Friends
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Messages
  alias Elektrine.Profiles
  alias Elektrine.Social
  alias Elektrine.Timeline.RateLimiter, as: TimelineRateLimiter

  action_fallback ElektrineWeb.FallbackController

  plug :enforce_timeline_read_limit
       when action in [:timeline, :public_timeline, :user_posts, :community_posts, :list_comments]

  # MARK: - Timeline

  @doc """
  GET /api/social/timeline
  Returns the user's personalized timeline feed.
  """
  def timeline(conn, params) do
    user = conn.assigns[:current_user]
    limit = parse_int(params["limit"], 20)
    pagination_opts = timeline_pagination_opts(params)

    posts = Social.get_timeline_feed(user.id, [limit: limit] ++ pagination_opts)
    next_cursor = get_next_cursor(posts, limit)

    conn
    |> put_status(:ok)
    |> json(%{
      posts: Enum.map(posts, &format_post(&1, user.id)),
      next_cursor: next_cursor
    })
  end

  @doc """
  GET /api/social/timeline/public
  Returns the public timeline.
  """
  def public_timeline(conn, params) do
    user = conn.assigns[:current_user]
    limit = parse_int(params["limit"], 20)
    pagination_opts = timeline_pagination_opts(params)

    posts = Social.get_public_timeline([limit: limit, user_id: user.id] ++ pagination_opts)
    next_cursor = get_next_cursor(posts, limit)

    conn
    |> put_status(:ok)
    |> json(%{
      posts: Enum.map(posts, &format_post(&1, user.id)),
      next_cursor: next_cursor
    })
  end

  @doc """
  GET /api/social/users/:user_id/posts
  Returns posts by a specific user.
  """
  def user_posts(conn, %{"user_id" => user_id} = params) do
    current_user = conn.assigns[:current_user]
    limit = parse_int(params["limit"], 20)
    pagination_opts = timeline_pagination_opts(params)

    posts =
      Social.get_user_timeline_posts(
        parse_int(user_id, 0),
        [limit: limit, viewer_id: current_user.id] ++ pagination_opts
      )

    next_cursor = get_next_cursor(posts, limit)

    conn
    |> put_status(:ok)
    |> json(%{
      posts: Enum.map(posts, &format_post(&1, current_user.id)),
      next_cursor: next_cursor
    })
  end

  # MARK: - Posts CRUD

  @doc """
  GET /api/social/posts/:id
  Returns a single post.
  """
  def show_post(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Messages.get_timeline_post(parse_int(id, 0)) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Post not found"})

      post ->
        conn
        |> put_status(:ok)
        |> json(%{post: format_post(post, user.id)})
    end
  end

  @doc """
  POST /api/social/posts
  Creates a new timeline post.
  """
  def create_post(conn, params) do
    user = conn.assigns[:current_user]

    content = params["content"] || ""
    visibility = params["visibility"] || "public"
    community_id = params["community_id"]
    media_urls = params["media_urls"] || []

    opts = [
      visibility: visibility,
      media_urls: media_urls
    ]

    opts =
      if community_id,
        do: Keyword.put(opts, :community_id, parse_int(community_id, nil)),
        else: opts

    case Social.create_timeline_post(user.id, content, opts) do
      {:ok, post} ->
        # Broadcast to followers via PubSub
        Phoenix.PubSub.broadcast(Elektrine.PubSub, "user:#{user.id}:followers", {:new_post, post})

        conn
        |> put_status(:created)
        |> json(%{post: format_post(post, user.id)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_errors(changeset)})
    end
  end

  @doc """
  DELETE /api/social/posts/:id
  Deletes a post.
  """
  def delete_post(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]
    post_id = parse_int(id, 0)

    case Messaging.delete_message(post_id, user.id) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Post deleted"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Post not found"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You can only delete your own posts"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to delete post: #{inspect(reason)}"})
    end
  end

  # MARK: - Likes

  @doc """
  POST /api/social/posts/:id/like
  Likes a post.
  """
  def like_post(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Social.like_post(user.id, parse_int(id, 0)) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Post liked"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to like post: #{inspect(reason)}"})
    end
  end

  @doc """
  DELETE /api/social/posts/:id/like
  Unlikes a post.
  """
  def unlike_post(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Social.unlike_post(user.id, parse_int(id, 0)) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Post unliked"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to unlike post: #{inspect(reason)}"})
    end
  end

  # MARK: - Reposts/Boosts

  @doc """
  POST /api/social/posts/:id/repost
  Reposts/boosts a post.
  """
  def repost(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Social.boost_post(user.id, parse_int(id, 0)) do
      {:ok, boost} ->
        conn
        |> put_status(:created)
        |> json(%{post: format_post(boost, user.id)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to repost: #{inspect(reason)}"})
    end
  end

  @doc """
  DELETE /api/social/posts/:id/repost
  Removes a repost.
  """
  def unrepost(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Social.unboost_post(user.id, parse_int(id, 0)) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Repost removed"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to remove repost: #{inspect(reason)}"})
    end
  end

  # MARK: - Comments

  @doc """
  GET /api/social/posts/:post_id/comments
  Returns comments on a post (replies).
  """
  def list_comments(conn, %{"post_id" => post_id} = params) do
    user = conn.assigns[:current_user]
    limit = parse_int(params["limit"], 50)

    # Get replies to this post
    comments =
      Social.get_unified_replies(parse_int(post_id, 0))
      |> Enum.take(limit)

    conn
    |> put_status(:ok)
    |> json(%{comments: Enum.map(comments, &format_comment(&1, user.id))})
  end

  @doc """
  POST /api/social/posts/:post_id/comments
  Creates a comment on a post (reply).
  """
  def create_comment(conn, %{"post_id" => post_id} = params) do
    user = conn.assigns[:current_user]
    content = params["content"] || ""

    # Comments are replies to posts
    opts = [reply_to_id: parse_int(post_id, 0)]

    case Social.create_timeline_post(user.id, content, opts) do
      {:ok, comment} ->
        conn
        |> put_status(:created)
        |> json(%{comment: format_comment(comment, user.id)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_errors(changeset)})
    end
  end

  @doc """
  DELETE /api/social/comments/:id
  Deletes a comment.
  """
  def delete_comment(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Messaging.delete_message(parse_int(id, 0), user.id) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Comment deleted"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Comment not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to delete comment: #{inspect(reason)}"})
    end
  end

  @doc """
  POST /api/social/comments/:id/like
  Likes a comment.
  """
  def like_comment(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    # Comments use the same like system as posts
    case Social.like_post(user.id, parse_int(id, 0)) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Comment liked"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to like comment: #{inspect(reason)}"})
    end
  end

  @doc """
  DELETE /api/social/comments/:id/like
  Unlikes a comment.
  """
  def unlike_comment(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    # Comments use the same like system as posts
    case Social.unlike_post(user.id, parse_int(id, 0)) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Comment unliked"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to unlike comment: #{inspect(reason)}"})
    end
  end

  # MARK: - Following

  @doc """
  GET /api/social/followers
  Returns current user's followers.
  """
  def list_followers(conn, _params) do
    user = conn.assigns[:current_user]
    followers = Profiles.get_followers(user.id)

    conn
    |> put_status(:ok)
    |> json(%{users: Enum.map(followers, &format_user(&1, user.id))})
  end

  @doc """
  GET /api/social/following
  Returns users the current user is following.
  """
  def list_following(conn, _params) do
    user = conn.assigns[:current_user]
    following = Profiles.get_following(user.id)

    conn
    |> put_status(:ok)
    |> json(%{users: Enum.map(following, &format_user(&1, user.id))})
  end

  @doc """
  GET /api/social/users/:user_id/followers
  Returns a user's followers.
  """
  def user_followers(conn, %{"user_id" => user_id}) do
    current_user = conn.assigns[:current_user]
    followers = Profiles.get_followers(parse_int(user_id, 0))

    conn
    |> put_status(:ok)
    |> json(%{users: Enum.map(followers, &format_user(&1, current_user.id))})
  end

  @doc """
  GET /api/social/users/:user_id/following
  Returns users a user is following.
  """
  def user_following(conn, %{"user_id" => user_id}) do
    current_user = conn.assigns[:current_user]
    following = Profiles.get_following(parse_int(user_id, 0))

    conn
    |> put_status(:ok)
    |> json(%{users: Enum.map(following, &format_user(&1, current_user.id))})
  end

  @doc """
  POST /api/social/users/:user_id/follow
  Follows a user.
  """
  def follow_user(conn, %{"user_id" => user_id}) do
    user = conn.assigns[:current_user]
    target_id = parse_int(user_id, 0)

    if target_id == user.id do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "Cannot follow yourself"})
    else
      case Profiles.follow_user(user.id, target_id) do
        {:ok, _} ->
          conn
          |> put_status(:ok)
          |> json(%{message: "Following user"})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to follow: #{inspect(reason)}"})
      end
    end
  end

  @doc """
  DELETE /api/social/users/:user_id/follow
  Unfollows a user.
  """
  def unfollow_user(conn, %{"user_id" => user_id}) do
    user = conn.assigns[:current_user]

    # Repo.delete_all returns {count, nil}
    case Profiles.unfollow_user(user.id, parse_int(user_id, 0)) do
      {count, _} when count > 0 ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Unfollowed user"})

      {0, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Not following this user"})

      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Unfollowed user"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to unfollow: #{inspect(reason)}"})
    end
  end

  # MARK: - Friend Requests

  @doc """
  GET /api/social/friend-requests
  Returns pending friend requests.
  """
  def list_friend_requests(conn, _params) do
    user = conn.assigns[:current_user]
    requests = Friends.list_pending_requests(user.id)

    conn
    |> put_status(:ok)
    |> json(%{friends: Enum.map(requests, &format_friend_request(&1, user.id))})
  end

  @doc """
  POST /api/social/friend-requests/:id/accept
  Accepts a friend request.
  """
  def accept_friend_request(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Friends.accept_friend_request(parse_int(id, 0), user.id) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Friend request accepted"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to accept: #{inspect(reason)}"})
    end
  end

  @doc """
  DELETE /api/social/friend-requests/:id
  Rejects a friend request.
  """
  def reject_friend_request(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Friends.reject_friend_request(parse_int(id, 0), user.id) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Friend request rejected"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to reject: #{inspect(reason)}"})
    end
  end

  # MARK: - Blocking

  @doc """
  POST /api/social/users/:user_id/block
  Blocks a user.
  """
  def block_user(conn, %{"user_id" => user_id}) do
    user = conn.assigns[:current_user]

    case Accounts.block_user(user.id, parse_int(user_id, 0)) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "User blocked"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to block: #{inspect(reason)}"})
    end
  end

  @doc """
  DELETE /api/social/users/:user_id/block
  Unblocks a user.
  """
  def unblock_user(conn, %{"user_id" => user_id}) do
    user = conn.assigns[:current_user]

    case Accounts.unblock_user(user.id, parse_int(user_id, 0)) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "User unblocked"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to unblock: #{inspect(reason)}"})
    end
  end

  # MARK: - User Profile

  @doc """
  GET /api/social/users/:id
  Returns a user's profile.
  """
  def show_user(conn, %{"id" => id}) do
    current_user = conn.assigns[:current_user]

    try do
      user = Accounts.get_user!(parse_int(id, 0))

      conn
      |> put_status(:ok)
      |> json(%{user: format_user(user, current_user.id)})
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})
    end
  end

  @doc """
  GET /api/social/users/search
  Searches for users.
  """
  def search_users(conn, %{"q" => query}) do
    current_user = conn.assigns[:current_user]
    users = Accounts.search_users(query, current_user.id)

    conn
    |> put_status(:ok)
    |> json(%{users: Enum.map(users, &format_user(&1, current_user.id))})
  end

  def search_users(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing search query"})
  end

  # MARK: - Communities

  @doc """
  GET /api/social/communities
  Returns all public communities (groups) with pagination.
  """
  def list_communities(conn, params) do
    # Cap limit at 50 to prevent DoS
    limit = min(parse_int(params["limit"], 20), 50)
    communities = Messaging.list_public_groups(limit: limit)

    conn
    |> put_status(:ok)
    |> json(%{communities: Enum.map(communities, &format_community/1)})
  end

  @doc """
  GET /api/social/communities/mine
  Returns communities the user is a member of.
  """
  def my_communities(conn, _params) do
    user = conn.assigns[:current_user]
    # Get user's conversations that are groups/communities
    conversations = Messaging.list_conversations(user.id)
    communities = Enum.filter(conversations, fn c -> c.type in ["group", "community"] end)

    conn
    |> put_status(:ok)
    |> json(%{communities: Enum.map(communities, &format_community/1)})
  end

  @doc """
  GET /api/social/communities/:id
  Returns a community.
  """
  def show_community(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    try do
      community = Messaging.get_conversation!(parse_int(id, 0), user.id)

      conn
      |> put_status(:ok)
      |> json(%{community: format_community(community)})
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Community not found"})
    end
  end

  @doc """
  GET /api/social/communities/:community_id/posts
  Returns posts in a community.
  """
  def community_posts(conn, %{"community_id" => community_id} = params) do
    user = conn.assigns[:current_user]
    limit = parse_int(params["limit"], 20)
    sort_by = params["sort_by"] || "recent"
    pagination_opts = timeline_pagination_opts(params)

    posts =
      Social.get_discussion_posts(
        parse_int(community_id, 0),
        [limit: limit, sort_by: sort_by] ++ pagination_opts
      )

    next_cursor = get_next_cursor(posts, limit)

    conn
    |> put_status(:ok)
    |> json(%{
      posts: Enum.map(posts, &format_post(&1, user.id)),
      next_cursor: next_cursor
    })
  end

  @doc """
  POST /api/social/communities
  Creates a new community.
  """
  def create_community(conn, params) do
    user = conn.assigns[:current_user]

    attrs = %{
      name: params["name"],
      description: params["description"],
      type: "group",
      is_public: params["is_public"] != false
    }

    case Messaging.create_group_conversation(user.id, attrs) do
      {:ok, community} ->
        conn
        |> put_status(:created)
        |> json(%{community: format_community(community)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_errors(changeset)})
    end
  end

  @doc """
  POST /api/social/communities/:id/join
  Joins a community.
  """
  def join_community(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Messaging.join_conversation(parse_int(id, 0), user.id) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Joined community"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to join: #{inspect(reason)}"})
    end
  end

  @doc """
  DELETE /api/social/communities/:id/join
  Leaves a community.
  """
  def leave_community(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Messaging.remove_member_from_conversation(parse_int(id, 0), user.id) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Left community"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to leave: #{inspect(reason)}"})
    end
  end

  @doc """
  GET /api/social/communities/search
  Searches for communities.
  """
  def search_communities(conn, %{"q" => query}) do
    user = conn.assigns[:current_user]
    communities = Messaging.search_public_conversations(query, user.id, 20)

    conn
    |> put_status(:ok)
    |> json(%{communities: Enum.map(communities, &format_community/1)})
  end

  def search_communities(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing search query"})
  end

  # MARK: - Media Upload

  @doc """
  POST /api/social/upload
  Uploads media for posts.
  """
  def upload_media(conn, %{"file" => _upload}) do
    conn
    |> put_status(:not_implemented)
    |> json(%{error: "Media upload not yet implemented"})
  end

  # MARK: - Private Helpers

  defp enforce_timeline_read_limit(conn, _opts) do
    identifier = timeline_rate_limit_identifier(conn)

    case TimelineRateLimiter.allow_read(identifier) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{error: "Timeline requests are temporarily rate-limited. Please retry shortly."})
        |> halt()
    end
  end

  defp timeline_rate_limit_identifier(conn) do
    base_identifier =
      case conn.assigns[:current_user] do
        %{id: user_id} -> "user:#{user_id}"
        _ -> "ip:#{client_ip(conn)}"
      end

    action = conn.private[:phoenix_action] || :timeline
    "timeline:#{action}:#{base_identifier}"
  end

  defp timeline_pagination_opts(params) do
    before_id = parse_int(params["before_id"] || params["max_id"] || params["cursor"], nil)
    since_id = parse_int(params["since_id"], nil)
    min_id = parse_int(params["min_id"], nil)
    order = normalize_order(params["order"], min_id)

    []
    |> maybe_put_option(:before_id, before_id)
    |> maybe_put_option(:since_id, since_id)
    |> maybe_put_option(:min_id, min_id)
    |> maybe_put_option(:order, order)
  end

  defp normalize_order(nil, min_id) when is_integer(min_id), do: "asc"
  defp normalize_order(nil, _min_id), do: nil

  defp normalize_order(order, _min_id) when is_binary(order) do
    normalized = String.downcase(order)

    if normalized in ["asc", "desc"] do
      normalized
    else
      nil
    end
  end

  defp normalize_order(_order, _min_id), do: nil

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: opts ++ [{key, value}]

  defp client_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp get_next_cursor(posts, limit) when length(posts) >= limit do
    case List.last(posts) do
      nil -> nil
      last_post -> "#{last_post.id}"
    end
  end

  defp get_next_cursor(_, _), do: nil

  defp format_post(post, current_user_id) do
    %{
      id: post.id,
      content: post.content,
      media_urls: post.media_urls || [],
      author_id: post.sender_id,
      community_id: post.conversation_id,
      visibility: post.visibility || "public",
      like_count: post.like_count || 0,
      comment_count: post.reply_count || 0,
      repost_count: post.share_count || 0,
      created_at: post.inserted_at,
      updated_at: post.updated_at,
      author: format_author(post.sender),
      community: format_post_community(post.conversation),
      is_liked: Social.user_liked_post?(current_user_id, post.id),
      is_reposted: Social.user_boosted?(current_user_id, post.id)
    }
  end

  defp format_author(nil), do: nil

  defp format_author(user) do
    %{
      id: user.id,
      username: user.username,
      display_name: user.display_name,
      avatar: user.avatar,
      verified: user.verified || false
    }
  end

  defp format_post_community(nil), do: nil

  defp format_post_community(%Ecto.Association.NotLoaded{}), do: nil

  defp format_post_community(conversation) do
    if conversation.type == "community" do
      %{
        id: conversation.id,
        name: conversation.name,
        avatar_url: conversation.avatar_url
      }
    else
      nil
    end
  end

  defp format_comment(comment, current_user_id) do
    %{
      id: comment.id,
      content: comment.content,
      author_id: comment.sender_id,
      post_id: comment.reply_to_id,
      parent_id: nil,
      like_count: comment.like_count || 0,
      reply_count: comment.reply_count || 0,
      created_at: comment.inserted_at,
      author: format_author(comment.sender),
      is_liked: Social.user_liked_post?(current_user_id, comment.id)
    }
  end

  defp format_user(user, current_user_id) do
    %{
      id: user.id,
      username: user.username,
      display_name: user.display_name,
      avatar: user.avatar_url,
      bio: user.bio,
      follower_count: Profiles.get_follower_count(user.id),
      following_count: Profiles.get_following_count(user.id),
      is_following: Profiles.following?(current_user_id, user.id),
      is_followed_by: Profiles.following?(user.id, current_user_id)
    }
  end

  defp format_friend_request(request, _current_user_id) do
    %{
      id: request.id,
      user_id: request.requester_id,
      friend_id: request.recipient_id,
      status: request.status,
      created_at: request.inserted_at,
      user: format_author(request.requester)
    }
  end

  defp format_community(community) do
    %{
      id: community.id,
      name: community.name,
      description: community.description,
      avatar_url: community.avatar_url,
      banner_url: nil,
      member_count: community.member_count || 0,
      post_count: nil,
      is_public: community.is_public,
      creator_id: community.creator_id,
      created_at: community.inserted_at,
      is_member: nil,
      role: nil
    }
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_errors(error), do: inspect(error)
end
