defmodule Elektrine.Developer.Exports.SocialExporter do
  @moduledoc """
  Exports user's social timeline data including posts, likes, and follows.

  Supported formats:
  - json: JSON format (most complete)
  - csv: CSV format for spreadsheet import
  """

  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Messaging.Message
  alias Elektrine.Social.PostLike
  alias Elektrine.Profiles.Follow

  @doc """
  Exports all social data for a user.

  Returns `{:ok, item_count}` on success.
  """
  def export(user_id, file_path, format, filters \\ %{}) do
    posts = fetch_posts(user_id, filters)
    likes = fetch_likes(user_id)
    follows = fetch_follows(user_id)

    count = length(posts) + length(likes) + length(follows.following) + length(follows.followers)

    data = %{
      posts: Enum.map(posts, &format_post/1),
      likes: Enum.map(likes, &format_like/1) |> Enum.reject(&is_nil/1),
      following: Enum.map(follows.following, &format_follow/1),
      followers: Enum.map(follows.followers, &format_follow/1)
    }

    case format do
      "json" -> export_json(data, file_path)
      "csv" -> export_csv(data, file_path)
      _ -> export_json(data, file_path)
    end

    {:ok, count}
  end

  defp fetch_posts(user_id, filters) do
    query =
      from m in Message,
        where: m.sender_id == ^user_id,
        where: is_nil(m.deleted_at),
        # Only public/followers posts, not DM/channel messages
        where: m.visibility in ["public", "followers", "unlisted"],
        order_by: [desc: m.inserted_at],
        preload: [:conversation, :link_preview, :hashtags]

    query = apply_filters(query, filters)

    Repo.all(query)
  end

  defp fetch_likes(user_id) do
    # Fetch local likes (PostLike has user_id and message_id)
    from(pl in PostLike,
      where: pl.user_id == ^user_id,
      preload: [:message]
    )
    |> Repo.all()
  end

  defp fetch_follows(user_id) do
    # Following uses :followed relationship (not :following)
    following =
      from(f in Follow,
        where: f.follower_id == ^user_id,
        order_by: [desc: f.inserted_at],
        preload: [:followed]
      )
      |> Repo.all()

    followers =
      from(f in Follow,
        where: f.followed_id == ^user_id,
        order_by: [desc: f.inserted_at],
        preload: [:follower]
      )
      |> Repo.all()

    %{following: following, followers: followers}
  end

  defp apply_filters(query, %{"from_date" => from_date}) when is_binary(from_date) do
    case DateTime.from_iso8601(from_date) do
      {:ok, dt, _} -> from(m in query, where: m.inserted_at >= ^dt)
      _ -> query
    end
  end

  defp apply_filters(query, %{"to_date" => to_date}) when is_binary(to_date) do
    case DateTime.from_iso8601(to_date) do
      {:ok, dt, _} -> from(m in query, where: m.inserted_at <= ^dt)
      _ -> query
    end
  end

  defp apply_filters(query, _), do: query

  defp export_json(data, file_path) do
    json = Jason.encode!(data, pretty: true)
    File.write!(file_path, json)
  end

  defp export_csv(data, file_path) do
    # For CSV, we'll export posts as the main data
    csv_content = posts_to_csv(data.posts)
    File.write!(file_path, csv_content)
  end

  defp posts_to_csv(posts) do
    headers = [
      "id",
      "content",
      "visibility",
      "type",
      "like_count",
      "reply_count",
      "share_count",
      "hashtags",
      "created_at"
    ]

    header_row = Enum.join(headers, ",")

    rows =
      posts
      |> Enum.map(fn post ->
        [
          to_string(post.id),
          escape_csv(post.content || ""),
          post.visibility,
          post.post_type,
          to_string(post.like_count),
          to_string(post.reply_count),
          to_string(post.share_count),
          escape_csv(Enum.join(post.hashtags, " ")),
          to_string(post.created_at)
        ]
        |> Enum.join(",")
      end)

    [header_row | rows] |> Enum.join("\n")
  end

  defp escape_csv(string) when is_binary(string) do
    if String.contains?(string, [",", "\"", "\n"]) do
      "\"" <> String.replace(string, "\"", "\"\"") <> "\""
    else
      string
    end
  end

  defp escape_csv(_), do: ""

  defp format_post(message) do
    hashtags =
      case message.hashtags do
        hashtags when is_list(hashtags) ->
          Enum.map(hashtags, fn h ->
            case h do
              %{name: name} -> name
              %{tag: tag} -> tag
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        _ ->
          message.extracted_hashtags || []
      end

    %{
      id: message.id,
      content: message.content,
      title: message.title,
      visibility: message.visibility,
      post_type: message.post_type,
      media_urls: message.media_urls,
      like_count: message.like_count,
      reply_count: message.reply_count,
      share_count: message.share_count,
      quote_count: message.quote_count,
      upvotes: message.upvotes,
      downvotes: message.downvotes,
      score: message.score,
      hashtags: hashtags,
      primary_url: message.primary_url,
      link_preview:
        if message.link_preview do
          %{
            url: message.link_preview.url,
            title: message.link_preview.title,
            description: message.link_preview.description,
            image_url: message.link_preview.image_url
          }
        else
          nil
        end,
      conversation_id: message.conversation_id,
      reply_to_id: message.reply_to_id,
      created_at: message.inserted_at,
      edited_at: message.edited_at
    }
  end

  defp format_like(%{message_id: _message_id, created_at: _created_at} = pl) do
    %{
      type: "local",
      message_id: pl.message_id,
      created_at: pl.created_at
    }
  end

  defp format_like(_), do: nil

  defp format_follow(follow) do
    user =
      cond do
        Ecto.assoc_loaded?(follow.follower) and follow.follower ->
          follow.follower

        Ecto.assoc_loaded?(follow.followed) and follow.followed ->
          follow.followed

        true ->
          nil
      end

    if user do
      %{
        user_id: user.id,
        username: user.username,
        handle: user.handle,
        display_name: user.display_name,
        followed_at: follow.inserted_at
      }
    else
      %{
        user_id: follow.follower_id || follow.followed_id,
        followed_at: follow.inserted_at
      }
    end
  end
end
