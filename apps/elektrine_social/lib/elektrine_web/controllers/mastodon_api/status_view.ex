defmodule ElektrineWeb.MastodonAPI.StatusView do
  @moduledoc """
  View module for rendering Mastodon API status (post) responses.
  """

  alias Elektrine.Repo

  import Ecto.Query

  @doc """
  Renders a status (message) in Mastodon API format.
  """
  def render_status(message, for_user) do
    base_url = ElektrineWeb.Endpoint.url()
    user = message.sender || Repo.preload(message, :sender).sender

    %{
      id: to_string(message.id),
      created_at: format_datetime(message.inserted_at),
      in_reply_to_id: message.reply_to_id && to_string(message.reply_to_id),
      in_reply_to_account_id: get_parent_account_id(message),
      sensitive: false,
      spoiler_text: "",
      visibility: message.visibility || "public",
      language: "en",
      uri: "#{base_url}/users/#{user.username}/statuses/#{message.id}",
      url: "#{base_url}/timeline/post/#{message.id}",
      replies_count: message.reply_count || 0,
      reblogs_count: message.share_count || 0,
      favourites_count: message.like_count || 0,
      edited_at: message.edited_at && format_datetime(message.edited_at),
      content: message.content || "",
      reblog: nil,
      application: nil,
      account: render_account(user, for_user),
      media_attachments: render_media_urls(message),
      mentions: [],
      tags: render_hashtags(message),
      emojis: [],
      card: nil,
      poll: nil,
      favourited: liked_by_user?(message, for_user),
      reblogged: reposted_by_user?(message, for_user),
      muted: false,
      bookmarked: false,
      pinned: false
    }
  end

  @doc """
  Renders multiple statuses.
  """
  def render_statuses(posts, for_user) do
    Enum.map(posts, &render_status(&1, for_user))
  end

  # Private functions

  defp render_account(user, _for_user) do
    base_url = ElektrineWeb.Endpoint.url()

    %{
      id: to_string(user.id),
      username: user.username,
      acct: user.username,
      display_name: user.display_name || user.username,
      locked: user.private || false,
      bot: false,
      discoverable: true,
      group: false,
      created_at: format_datetime(user.inserted_at),
      note: user.bio || "",
      url: "#{base_url}/#{user.username}",
      avatar: Elektrine.Uploads.avatar_url(user.avatar),
      avatar_static: Elektrine.Uploads.avatar_url(user.avatar),
      header: Elektrine.Uploads.background_url(user.background),
      header_static: Elektrine.Uploads.background_url(user.background),
      followers_count: 0,
      following_count: 0,
      statuses_count: 0,
      last_status_at: nil,
      emojis: [],
      fields: []
    }
  end

  defp render_media_urls(%{media_urls: urls, media_metadata: metadata})
       when is_list(urls) and urls != [] do
    urls
    |> Enum.with_index()
    |> Enum.map(fn {url, index} ->
      meta = if is_map(metadata), do: Map.get(metadata, to_string(index), %{}), else: %{}

      %{
        id: to_string(index),
        type: detect_media_type(meta["content_type"]),
        url: url,
        preview_url: meta["thumbnail"] || url,
        remote_url: nil,
        meta: %{},
        description: meta["alt_text"],
        blurhash: meta["blurhash"]
      }
    end)
  end

  defp render_media_urls(_), do: []

  defp detect_media_type(nil), do: "image"

  defp detect_media_type(content_type) when is_binary(content_type) do
    cond do
      String.starts_with?(content_type, "image/gif") -> "gifv"
      String.starts_with?(content_type, "image/") -> "image"
      String.starts_with?(content_type, "video/") -> "video"
      String.starts_with?(content_type, "audio/") -> "audio"
      true -> "unknown"
    end
  end

  defp detect_media_type(_), do: "image"

  defp render_hashtags(%{extracted_hashtags: hashtags}) when is_list(hashtags) do
    base_url = ElektrineWeb.Endpoint.url()

    Enum.map(hashtags, fn tag ->
      %{
        name: tag,
        url: "#{base_url}/hashtag/#{tag}"
      }
    end)
  end

  defp render_hashtags(_), do: []

  defp get_parent_account_id(%{reply_to_id: nil}), do: nil

  defp get_parent_account_id(%{reply_to_id: reply_to_id}) do
    case Repo.one(from(m in "messages", where: m.id == ^reply_to_id, select: m.sender_id)) do
      nil -> nil
      user_id -> to_string(user_id)
    end
  rescue
    _ -> nil
  end

  defp liked_by_user?(_message, nil), do: false

  defp liked_by_user?(%{id: message_id}, %{id: user_id}) do
    Repo.exists?(
      from(r in "message_reactions",
        where: r.message_id == ^message_id and r.user_id == ^user_id and r.emoji == "like"
      )
    )
  rescue
    _ -> false
  end

  defp reposted_by_user?(_message, nil), do: false

  defp reposted_by_user?(%{id: message_id}, %{id: user_id}) do
    # Check if user has shared/boosted this message
    Repo.exists?(
      from(m in "messages",
        where: m.shared_message_id == ^message_id and m.sender_id == ^user_id
      )
    )
  rescue
    _ -> false
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
