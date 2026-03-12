defmodule ElektrineWeb.API.ExtSocialController do
  @moduledoc """
  External API controller for read-only social access.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Friends
  alias Elektrine.Messaging.Messages
  alias Elektrine.Profiles
  alias Elektrine.Social
  alias ElektrineWeb.API.Response

  @default_limit 20
  @max_limit 100
  @doc """
  GET /api/ext/v1/social/feed
  """
  def feed(conn, params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_limit) |> min(@max_limit)
    scope = params["scope"] || "home"

    case scope do
      "home" ->
        posts = Social.get_timeline_feed(user.id, limit: limit)

        Response.ok(conn, %{scope: scope, posts: Enum.map(posts, &format_post(&1, user.id))}, %{
          pagination: %{limit: limit}
        })

      "public" ->
        posts = Social.get_public_timeline(limit: limit, user_id: user.id)

        Response.ok(conn, %{scope: scope, posts: Enum.map(posts, &format_post(&1, user.id))}, %{
          pagination: %{limit: limit}
        })

      _ ->
        Response.error(conn, :bad_request, "invalid_scope", "Invalid feed scope")
    end
  end

  @doc """
  GET /api/ext/v1/social/posts/:id
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, post_id} <- parse_id(id),
         post when not is_nil(post) <- Messages.get_timeline_post(post_id),
         true <- social_post?(post),
         true <- can_view_post?(post, user.id) do
      Response.ok(conn, %{post: format_post(post, user.id)})
    else
      {:error, :invalid_id} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid post id")

      _ ->
        Response.error(conn, :not_found, "not_found", "Post not found")
    end
  end

  @doc """
  GET /api/ext/v1/social/users/:user_id/posts
  """
  def user_posts(conn, %{"user_id" => user_id} = params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_limit) |> min(@max_limit)

    with {:ok, author_id} <- parse_id(user_id) do
      posts =
        Social.get_user_timeline_posts(author_id,
          viewer_id: user.id,
          limit: limit
        )

      Response.ok(
        conn,
        %{user_id: author_id, posts: Enum.map(posts, &format_post(&1, user.id))},
        %{pagination: %{limit: limit}}
      )
    else
      {:error, :invalid_id} ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid user id")
    end
  end

  defp social_post?(post) do
    Map.get(post, :post_type) not in ["message", nil]
  end

  defp can_view_post?(post, viewer_id) do
    owner? = not is_nil(post.sender_id) and viewer_id == post.sender_id
    approved? = post.approval_status in ["approved", nil]

    visible? =
      case post.visibility do
        "public" -> true
        "unlisted" -> true
        "followers" -> owner? or Profiles.following?(viewer_id, post.sender_id)
        "friends" -> owner? or Friends.are_friends?(viewer_id, post.sender_id)
        "private" -> owner?
        _ -> false
      end

    visible? and is_nil(post.deleted_at) and (approved? or owner?)
  end

  defp format_post(post, current_user_id) do
    %{
      id: post.id,
      post_type: post.post_type,
      content: post.content,
      title: post.title,
      media_urls: post.media_urls || [],
      visibility: post.visibility || "public",
      content_warning: post.content_warning,
      sensitive: post.sensitive || false,
      author_id: post.sender_id,
      author: format_author(post.sender),
      remote_actor: format_remote_actor(post.remote_actor),
      community: format_community(post.conversation),
      like_count: post.like_count || 0,
      comment_count: post.reply_count || 0,
      repost_count: post.share_count || 0,
      quote_count: post.quote_count || 0,
      is_liked: Social.user_liked_post?(current_user_id, post.id),
      is_reposted: Social.user_boosted?(current_user_id, post.id),
      inserted_at: post.inserted_at,
      updated_at: post.updated_at
    }
  end

  defp format_author(nil), do: nil
  defp format_author(%Ecto.Association.NotLoaded{}), do: nil

  defp format_author(user) do
    %{
      id: user.id,
      username: user.username,
      handle: user.handle,
      display_name: user.display_name,
      avatar: user.avatar,
      verified: user.verified || false
    }
  end

  defp format_remote_actor(nil), do: nil
  defp format_remote_actor(%Ecto.Association.NotLoaded{}), do: nil

  defp format_remote_actor(actor) do
    %{
      id: actor.id,
      username: actor.username,
      display_name: actor.display_name,
      domain: actor.domain,
      avatar_url: actor.avatar_url,
      uri: actor.uri
    }
  end

  defp format_community(nil), do: nil
  defp format_community(%Ecto.Association.NotLoaded{}), do: nil

  defp format_community(conversation) do
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

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_id(_value), do: {:error, :invalid_id}

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_value, default), do: default
end
