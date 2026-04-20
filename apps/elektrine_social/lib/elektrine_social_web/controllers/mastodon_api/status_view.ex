defmodule ElektrineSocialWeb.MastodonAPI.StatusView do
  @moduledoc """
  View module for rendering Mastodon API status (post) responses.
  """

  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Uploads

  import Ecto.Query

  @doc """
  Renders a status (message) in Mastodon API format.
  """
  def render_status(message, for_user) do
    base_url = ElektrineWeb.Endpoint.url()
    message = ensure_status_preloads(message)

    %{
      id: to_string(message.id),
      created_at: format_datetime(message.inserted_at),
      in_reply_to_id: message.reply_to_id && to_string(message.reply_to_id),
      in_reply_to_account_id: get_parent_account_id(message),
      sensitive: Map.get(message, :sensitive, false),
      spoiler_text: Map.get(message, :content_warning) || "",
      visibility: message.visibility || "public",
      language: "en",
      uri: status_uri(base_url, message),
      url: "#{base_url}/timeline/post/#{message.id}",
      replies_count: message.reply_count || 0,
      reblogs_count: message.share_count || 0,
      favourites_count: message.like_count || 0,
      edited_at: message.edited_at && format_datetime(message.edited_at),
      content: message.content || "",
      reblog: nil,
      application: nil,
      account: render_status_account(message, for_user),
      media_attachments: render_media_urls(message),
      mentions: [],
      tags: render_hashtags(message),
      emojis: [],
      card: nil,
      poll: render_poll(Map.get(message, :poll), for_user),
      favourited: liked_by_user?(message, for_user),
      reblogged: reposted_by_user?(message, for_user),
      muted: false,
      bookmarked: bookmarked_by_user?(message, for_user),
      pinned: false
    }
  end

  @doc """
  Renders multiple statuses.
  """
  def render_statuses(posts, for_user) do
    Enum.map(posts, &render_status(&1, for_user))
  end

  @doc """
  Renders an account in Mastodon API format.
  """
  def render_account(user, _for_user) do
    base_url = ElektrineWeb.Endpoint.url()
    header = account_header(user)

    %{
      id: to_string(user.id),
      username: user.username,
      acct: user.username,
      display_name: user.display_name || user.username,
      locked:
        Map.get(user, :private, Map.get(user, :activitypub_manually_approve_followers, false)),
      bot: false,
      discoverable: Map.get(user, :profile_visibility, "public") == "public",
      group: false,
      created_at: format_datetime(user.inserted_at),
      note: account_note(user),
      url: "#{base_url}/#{user.username}",
      avatar: Uploads.avatar_url(user.avatar),
      avatar_static: Uploads.avatar_url(user.avatar),
      header: Uploads.background_url(header),
      header_static: Uploads.background_url(header),
      followers_count: Profiles.get_follower_count(user.id),
      following_count: Profiles.get_following_count(user.id),
      statuses_count: Map.get(user, :message_count, 0),
      last_status_at: nil,
      emojis: [],
      fields: []
    }
  end

  def render_accounts(users, for_user) do
    Enum.map(users, &render_account(&1, for_user))
  end

  def render_poll(nil, _for_user), do: nil
  def render_poll(%Ecto.Association.NotLoaded{}, _for_user), do: nil

  def render_poll(poll, for_user) do
    poll = Repo.preload(poll, [:options])
    own_votes = if for_user, do: Social.get_user_poll_votes(poll.id, for_user.id), else: []

    %{
      id: to_string(poll.id),
      expires_at: format_datetime(poll.closes_at),
      expired: Elektrine.Social.Poll.closed?(poll),
      multiple: poll.allow_multiple,
      votes_count: poll.total_votes || 0,
      voters_count: poll.voters_count || poll.total_votes || 0,
      voted: own_votes != [],
      own_votes: Enum.map(own_votes, &to_string/1),
      options:
        poll.options
        |> Enum.sort_by(& &1.position)
        |> Enum.map(fn option ->
          %{title: option.option_text, votes_count: option.vote_count || 0}
        end),
      emojis: []
    }
  end

  # Private functions

  defp render_media_urls(%{media_urls: urls, media_metadata: metadata})
       when is_list(urls) and urls != [] do
    urls
    |> Enum.with_index()
    |> Enum.map(fn {url, index} ->
      meta = if is_map(metadata), do: Map.get(metadata, to_string(index), %{}), else: %{}

      %{
        id: to_string(index),
        type: detect_media_type(meta["content_type"]),
        url: Uploads.attachment_url(url),
        preview_url: meta["thumbnail"] || Uploads.attachment_url(url),
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

  defp ensure_status_preloads(message) do
    Repo.preload(message, [:sender, :remote_actor, poll: [:options]])
  end

  defp render_status_account(%{sender: sender}, for_user) when not is_nil(sender),
    do: render_account(sender, for_user)

  defp render_status_account(%{remote_actor: actor}, _for_user) when not is_nil(actor),
    do: render_remote_account(actor)

  defp render_status_account(_message, _for_user), do: nil

  defp render_remote_account(actor) do
    %{
      id: to_string(actor.id),
      username: actor.username,
      acct: "#{actor.username}@#{actor.domain}",
      display_name: actor.display_name || actor.username,
      locked: actor.manually_approves_followers || false,
      bot: actor.actor_type in ["Service", "Application"],
      discoverable: true,
      group: actor.actor_type == "Group",
      created_at: format_datetime(actor.published_at || actor.inserted_at),
      note: actor.summary || "",
      url: actor.uri,
      avatar: actor.avatar_url,
      avatar_static: actor.avatar_url,
      header: actor.header_url,
      header_static: actor.header_url,
      followers_count: 0,
      following_count: 0,
      statuses_count: 0,
      last_status_at: nil,
      emojis: [],
      fields: []
    }
  end

  defp status_uri(base_url, %{sender: sender, id: id}) when not is_nil(sender),
    do: "#{base_url}/users/#{sender.username}/statuses/#{id}"

  defp status_uri(_base_url, %{activitypub_id: activitypub_id})
       when is_binary(activitypub_id) and activitypub_id != "",
       do: activitypub_id

  defp status_uri(base_url, %{id: id}), do: "#{base_url}/timeline/post/#{id}"

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
    Social.user_liked_post?(user_id, message_id)
  rescue
    _ -> false
  end

  defp reposted_by_user?(_message, nil), do: false

  defp reposted_by_user?(%{id: message_id}, %{id: user_id}) do
    Social.user_boosted?(user_id, message_id)
  rescue
    _ -> false
  end

  def bookmarked_by_user?(_message, nil), do: false

  def bookmarked_by_user?(%{id: message_id}, %{id: user_id}) do
    Social.post_saved?(user_id, message_id)
  rescue
    _ -> false
  end

  defp account_note(%{profile: %Ecto.Association.NotLoaded{}} = user),
    do: Map.get(user, :bio) || ""

  defp account_note(%{profile: nil} = user), do: Map.get(user, :bio) || ""

  defp account_note(%{profile: profile} = user) when is_map(profile) do
    Map.get(profile, :description) || Map.get(user, :bio) || ""
  end

  defp account_note(user), do: Map.get(user, :bio) || ""

  defp account_header(%{profile: %Ecto.Association.NotLoaded{}} = user),
    do: Map.get(user, :background)

  defp account_header(%{profile: nil} = user), do: Map.get(user, :background)

  defp account_header(%{profile: profile} = user) when is_map(profile) do
    Map.get(profile, :banner_url) || Map.get(profile, :background_url) ||
      Map.get(user, :background)
  end

  defp account_header(user), do: Map.get(user, :background)

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
