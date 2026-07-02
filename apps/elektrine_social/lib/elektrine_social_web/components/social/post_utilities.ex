defmodule ElektrineSocialWeb.Components.Social.PostUtilities do
  @moduledoc """
  Shared utility functions for post rendering components.
  Provides common functionality for TimelinePost, LemmyPost, and other post components.
  """

  import Ecto.Query, only: [from: 2]

  alias Elektrine.ActivityPub.LemmyApi
  alias Elektrine.Repo
  alias Elektrine.Security.SafeExternalURL
  alias Elektrine.Social.LinkPreview
  alias Elektrine.Social.Message
  alias Elektrine.Uploads
  alias ElektrineWeb.HtmlHelpers

  @public_audience_uris MapSet.new([
                          "Public",
                          "as:Public",
                          "https://www.w3.org/ns/activitystreams#Public"
                        ])
  @user_actor_path_markers [
    "/users/",
    "/user/",
    "/u/",
    "/@",
    "/profile/",
    "/profiles/",
    "/accounts/"
  ]
  @community_path_markers ["/c/", "/m/", "/community/", "/communities/", "/groups/", "/g/"]

  @doc """
  Checks if the given URL is a video file based on extension.
  """
  @spec video_url?(String.t() | nil) :: boolean()
  def video_url?(url) when is_binary(url) do
    String.match?(String.downcase(url), ~r/\.(mp4|webm|ogv|mov)(\?.*)?$/)
  end

  def video_url?(_), do: false

  @doc """
  Checks if the given URL is an audio file based on extension.
  """
  @spec audio_url?(String.t() | nil) :: boolean()
  def audio_url?(url) when is_binary(url) do
    String.match?(String.downcase(url), ~r/\.(mp3|wav|m4a|aac|flac|oga|opus|ogg)(\?.*)?$/)
  end

  def audio_url?(_), do: false

  @doc """
  Filters a list of URLs to return only image URLs.
  Matches common image extensions and image hosting patterns.
  """
  @spec filter_image_urls(list(String.t()) | nil) :: list(String.t())
  def filter_image_urls(urls) when is_list(urls) do
    urls
    |> Enum.map(&safe_image_url/1)
    |> Enum.reject(&is_nil/1)
  end

  def filter_image_urls(_), do: []

  @doc "Returns a safe external image URL, or nil for unsafe/non-image values."
  @spec safe_image_url(String.t() | nil) :: String.t() | nil
  def safe_image_url(url) when is_binary(url) do
    with trimmed when trimmed != "" <- String.trim(url),
         true <- image_url?(trimmed),
         {:ok, safe_url} <- SafeExternalURL.normalize(trimmed) do
      safe_url
    else
      _ -> nil
    end
  end

  def safe_image_url(_), do: nil

  @doc "Returns a safe external href URL, or nil for unsafe values."
  @spec safe_external_href(String.t() | nil) :: String.t() | nil
  def safe_external_href(url) when is_binary(url) do
    case SafeExternalURL.normalize_href(url) do
      {:ok, safe_url} -> safe_url
      {:error, _reason} -> nil
    end
  end

  def safe_external_href(_), do: nil

  defp image_url?(url) when is_binary(url) do
    String.match?(url, ~r/\.(jpe?g|png|gif|webp|svg|bmp|avif)(\?.*)?$/i) ||
      String.match?(
        url,
        ~r/(\/media\/|\/images\/|\/uploads\/|\/pictrs\/|i\.imgur|pbs\.twimg|i\.redd\.it)/i
      )
  end

  @doc """
  Extracts the community name from a Lemmy community URI.
  Returns the community name prefixed with '!' for Lemmy-style display.
  """
  @spec extract_community_name(String.t() | nil) :: String.t()
  def extract_community_name(uri) when is_binary(uri) do
    if String.contains?(uri, "/c/") do
      # Lemmy style: https://lemmy.world/c/community
      name = uri |> String.split("/c/") |> List.last() |> String.split("/") |> List.first()
      "!#{name}"
    else
      # Fallback: just get last path segment
      uri |> URI.parse() |> Map.get(:path, "") |> String.split("/") |> List.last()
    end
  end

  def extract_community_name(_), do: ""

  @doc """
  Extracts the community name from a URI, without the '!' prefix.
  Used for simpler display contexts.
  """
  @spec extract_community_name_simple(String.t() | nil) :: String.t()
  def extract_community_name_simple(uri) when is_binary(uri) do
    uri
    |> String.split("/")
    |> List.last()
    |> String.replace_prefix("!", "")
  end

  def extract_community_name_simple(_), do: "Community"

  @doc """
  Detects a submitted external link for a federated post.

  Remote status permalinks often appear in `url`, `primary_url`, or stale preview
  metadata. Those are the post itself, not a submitted article link, so they are
  filtered out before render-time link previews are considered.
  """
  @spec detect_external_link(map()) :: String.t() | nil
  def detect_external_link(post) do
    [
      Map.get(post, :primary_url),
      media_metadata_external_link(post),
      Map.get(post, :activitypub_url),
      extract_url_from_content(Map.get(post, :content))
    ]
    |> Enum.find_value(&submitted_external_link(post, &1))
  end

  @doc """
  Returns the loaded link preview only when it points at a real submitted link.
  """
  @spec visible_link_preview(map()) :: map() | nil
  def visible_link_preview(post) when is_map(post) do
    preview = Map.get(post, :link_preview)

    if visible_link_preview?(post, preview), do: preview
  end

  def visible_link_preview(_), do: nil

  @doc """
  Returns true when a URL points back to the same ActivityPub object as the post.
  """
  @spec self_referential_link?(map(), String.t() | nil) :: boolean()
  def self_referential_link?(post, url) when is_map(post) and is_binary(url) do
    case parse_http_uri(url) do
      %URI{host: candidate_host} = candidate_uri when is_binary(candidate_host) ->
        post_identity_uris(post)
        |> Enum.any?(&same_activitypub_resource?(candidate_uri, &1))

      _ ->
        false
    end
  end

  def self_referential_link?(_, _), do: false

  @doc """
  Extracts the first HTTP URL from HTML content.
  """
  @spec extract_url_from_content(String.t() | nil) :: String.t() | nil
  def extract_url_from_content(nil), do: nil

  def extract_url_from_content(content) when is_binary(content) do
    case Regex.run(~r/<a[^>]+href=["']([^"']+)["'][^>]*>/i, content) do
      [_, url] when is_binary(url) ->
        if String.starts_with?(url, "http"), do: url, else: nil

      _ ->
        nil
    end
  end

  def extract_url_from_content(_), do: nil

  defp media_metadata_external_link(post) do
    case Map.get(post, :media_metadata) do
      %{} = metadata -> Map.get(metadata, "external_link")
      _ -> nil
    end
  end

  defp submitted_external_link(post, url) when is_binary(url) do
    with trimmed when trimmed != "" <- String.trim(url),
         {:ok, safe_url} <- SafeExternalURL.normalize_href(trimmed),
         false <- self_referential_link?(post, safe_url) do
      safe_url
    else
      _ -> nil
    end
  end

  defp submitted_external_link(_, _), do: nil

  defp visible_link_preview?(post, %LinkPreview{status: "success", url: url})
       when is_binary(url) do
    submitted_external_link(post, url) != nil
  end

  defp visible_link_preview?(_, _), do: false

  defp post_identity_uris(post) do
    id_uri = parse_http_uri(Map.get(post, :activitypub_id))
    url_uri = parse_http_uri(Map.get(post, :activitypub_url))

    [id_uri]
    |> maybe_add_same_instance_permalink(id_uri, url_uri)
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_add_same_instance_permalink(uris, %URI{} = id_uri, %URI{} = url_uri) do
    if same_host?(id_uri.host, url_uri.host), do: [url_uri | uris], else: uris
  end

  defp maybe_add_same_instance_permalink(uris, _, _), do: uris

  defp parse_http_uri(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        uri

      _ ->
        nil
    end
  rescue
    URI.Error -> nil
  end

  defp parse_http_uri(_), do: nil

  defp same_activitypub_resource?(%URI{} = candidate_uri, %URI{} = identity_uri) do
    same_host?(candidate_uri.host, identity_uri.host) &&
      (same_normalized_path?(candidate_uri, identity_uri) ||
         same_activitypub_object_token?(candidate_uri, identity_uri))
  end

  defp same_host?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(left) == String.downcase(right)

  defp same_host?(_, _), do: false

  defp same_normalized_path?(left_uri, right_uri) do
    normalize_uri_path(left_uri.path) == normalize_uri_path(right_uri.path)
  end

  defp normalize_uri_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp normalize_uri_path(_), do: nil

  defp same_activitypub_object_token?(left_uri, right_uri) do
    case {activitypub_object_token(left_uri), activitypub_object_token(right_uri)} do
      {left, right} when is_binary(left) and left != "" and left == right -> true
      _ -> false
    end
  end

  defp activitypub_object_token(%URI{path: path}) when is_binary(path) do
    segments = String.split(path, "/", trim: true)

    cond do
      token = token_after_marker(segments) ->
        token

      match?(["@" <> _, _ | _], segments) ->
        Enum.at(segments, 1)

      true ->
        nil
    end
  end

  defp activitypub_object_token(_), do: nil

  defp token_after_marker(segments) do
    markers = ~w(status statuses post posts note notes object objects activity activities)

    segments
    |> Enum.with_index()
    |> Enum.find_value(fn {segment, index} ->
      if segment in markers, do: Enum.at(segments, index + 1)
    end)
  end

  @doc """
  Attaches cached link previews by external URL for posts that do not already have
  a loaded `link_preview` association.
  """
  @spec attach_cached_link_previews(list(map())) :: list(map())
  def attach_cached_link_previews(posts) when is_list(posts) do
    urls =
      posts
      |> Enum.filter(&missing_loaded_link_preview?/1)
      |> Enum.map(&detect_external_link/1)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    previews_by_url =
      if urls == [] do
        %{}
      else
        from(lp in LinkPreview, where: lp.url in ^urls)
        |> Repo.all()
        |> Map.new(&{&1.url, &1})
      end

    Enum.map(posts, &attach_cached_link_preview(&1, previews_by_url))
  end

  def attach_cached_link_previews(_), do: []

  defp attach_cached_link_preview(post, previews_by_url) when is_map(post) do
    if missing_loaded_link_preview?(post) do
      case detect_external_link(post) do
        url when is_binary(url) ->
          case Map.get(previews_by_url, url) do
            nil -> post
            preview -> Map.put(post, :link_preview, preview)
          end

        _ ->
          post
      end
    else
      post
    end
  end

  defp attach_cached_link_preview(post, _), do: post

  defp missing_loaded_link_preview?(%{link_preview: %Ecto.Association.NotLoaded{}}), do: true
  defp missing_loaded_link_preview?(%{link_preview: nil}), do: true
  defp missing_loaded_link_preview?(%{link_preview: _preview}), do: false
  defp missing_loaded_link_preview?(_), do: true

  @doc """
  Renders content preview with HTML stripped, length limited, and emoji decoding.

  Decoding order:
  1. Strip HTML and truncate to preview length
  2. Escape remaining text for safe raw rendering
  3. Convert known shortcode aliases to Unicode
  4. Render custom emojis when shortcode patterns remain
  """
  @spec render_content_preview(String.t() | nil, String.t() | nil, non_neg_integer()) ::
          String.t()
  def render_content_preview(content, instance_domain \\ nil, max_length \\ 200)
  def render_content_preview(nil, _instance_domain, _max_length), do: ""

  def render_content_preview(content, instance_domain, max_length)
      when is_binary(content) and is_integer(max_length) and max_length >= 0 do
    content
    |> plain_text_preview(max_length)
    |> HtmlHelpers.escape_html()
    |> HtmlHelpers.convert_emoji_shortcodes()
    |> maybe_render_custom_emojis(instance_domain)
  end

  def render_content_preview(_, _instance_domain, _max_length), do: ""

  @doc """
  Converts possibly-HTML content into normalized plain text.
  """
  @spec plain_text_content(String.t() | nil) :: String.t()
  def plain_text_content(content), do: HtmlHelpers.plain_text_content(content)

  @doc """
  Returns a truncated plain-text preview for possibly-HTML content.
  """
  @spec plain_text_preview(String.t() | nil, non_neg_integer()) :: String.t()
  def plain_text_preview(content, max_length \\ 200),
    do: HtmlHelpers.plain_text_preview(content, max_length)

  @doc """
  Extracts the best-guess instance domain for remote/custom emoji rendering.
  """
  @spec get_instance_domain(map() | Message.t() | nil) :: String.t() | nil
  def get_instance_domain(%Message{} = message) do
    message
    |> remote_actor_domain()
    |> Kernel.||(host_from_uri(message.activitypub_id))
    |> Kernel.||(host_from_uri(message.activitypub_url))
  end

  def get_instance_domain(item) when is_map(item) do
    item
    |> remote_actor_domain()
    |> Kernel.||(Map.get(item, :author_domain) || Map.get(item, "author_domain"))
    |> Kernel.||(host_from_uri(Map.get(item, :activitypub_id) || Map.get(item, "activitypub_id")))
    |> Kernel.||(
      host_from_uri(Map.get(item, :activitypub_url) || Map.get(item, "activitypub_url"))
    )
  end

  def get_instance_domain(_), do: nil

  @doc """
  Formats reactions for display, grouping by emoji.
  Returns list of {emoji, count, user_names, current_user_reacted}.
  """
  @spec format_reactions(list() | nil | Ecto.Association.NotLoaded.t(), integer() | nil) ::
          list({String.t(), integer(), list(String.t()), boolean()})
  def format_reactions(%Ecto.Association.NotLoaded{}, _user_id), do: []
  def format_reactions(nil, _user_id), do: []
  def format_reactions([], _user_id), do: []

  def format_reactions(reactions, current_user_id) when is_list(reactions) do
    reactions
    |> Enum.group_by(& &1.emoji)
    |> Enum.map(fn {emoji, emoji_reactions} ->
      users =
        Enum.map(emoji_reactions, fn r ->
          cond do
            r.user && (r.user.handle || r.user.username) ->
              r.user.handle || r.user.username

            r.remote_actor && r.remote_actor.username ->
              "#{r.remote_actor.username}@#{r.remote_actor.domain}"

            true ->
              "someone"
          end
        end)

      user_reacted =
        current_user_id &&
          Enum.any?(emoji_reactions, fn r ->
            r.user_id == current_user_id
          end)

      {emoji, reaction_group_count(emoji_reactions), users, user_reacted || false}
    end)
    |> Enum.sort_by(fn {_, count, _, _} -> -count end)
  end

  def format_reactions(_, _user_id), do: []

  defp reaction_group_count(reactions) when is_list(reactions) do
    Enum.reduce(reactions, 0, fn reaction, total -> total + reaction_count(reaction) end)
  end

  defp reaction_count(reaction) when is_map(reaction) do
    case Map.get(reaction, :remote_count) || Map.get(reaction, "remote_count") do
      count when is_integer(count) and count > 0 ->
        count

      count when is_binary(count) ->
        case Integer.parse(String.trim(count)) do
          {parsed, _} when parsed > 0 -> parsed
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp reaction_count(_), do: 1

  @doc """
  Gets the author display string from a reply.
  Handles both Lemmy API maps and local Message structs.
  """
  @spec get_reply_author(map() | Message.t()) :: String.t()
  def get_reply_author(%Message{} = msg) do
    cond do
      msg.remote_actor && msg.remote_actor.username ->
        "@#{msg.remote_actor.username}@#{msg.remote_actor.domain}"

      msg.sender && msg.sender.username ->
        "@#{msg.sender.username}"

      true ->
        ""
    end
  end

  def get_reply_author(%{author: author, author_domain: domain}) when is_binary(author) do
    if domain, do: "@#{author}@#{domain}", else: "@#{author}"
  end

  def get_reply_author(%{"author" => author, "author_domain" => domain}) when is_binary(author) do
    if domain, do: "@#{author}@#{domain}", else: "@#{author}"
  end

  def get_reply_author(%{remote_actor: %{username: username, domain: domain}}) do
    "@#{username}@#{domain}"
  end

  def get_reply_author(%{"remote_actor" => %{"username" => username, "domain" => domain}}) do
    "@#{username}@#{domain}"
  end

  def get_reply_author(%{remote_actor: %{username: username}}) do
    "@#{username}"
  end

  def get_reply_author(%{"remote_actor" => %{"username" => username}}) do
    "@#{username}"
  end

  def get_reply_author(%{sender: %{username: username}}) do
    "@#{username}"
  end

  def get_reply_author(%{"sender" => %{"username" => username}}) do
    "@#{username}"
  end

  def get_reply_author(_), do: ""

  @doc """
  Gets the avatar URL from a reply.
  Handles local messages, federated messages, and Lemmy API comment maps.
  """
  @spec get_reply_avatar_url(map() | Message.t()) :: String.t() | nil
  def get_reply_avatar_url(%Message{} = msg) do
    cond do
      msg.remote_actor && Elektrine.Strings.present?(msg.remote_actor.avatar_url) ->
        safe_image_url(msg.remote_actor.avatar_url)

      msg.sender && Elektrine.Strings.present?(msg.sender.avatar) ->
        Uploads.avatar_url(msg.sender.avatar)

      true ->
        nil
    end
  end

  def get_reply_avatar_url(reply) when is_map(reply) do
    remote_actor = Map.get(reply, :remote_actor) || Map.get(reply, "remote_actor")
    sender = Map.get(reply, :sender) || Map.get(reply, "sender")
    local_user = Map.get(reply, :_local_user) || Map.get(reply, "_local_user")
    lemmy_data = Map.get(reply, :_lemmy) || Map.get(reply, "_lemmy")

    remote_candidates = [
      Map.get(reply, :author_avatar),
      Map.get(reply, "author_avatar"),
      Map.get(reply, :avatar_url),
      Map.get(reply, "avatar_url"),
      remote_actor && (Map.get(remote_actor, :avatar_url) || Map.get(remote_actor, "avatar_url")),
      lemmy_data &&
        (Map.get(lemmy_data, :creator_avatar) || Map.get(lemmy_data, "creator_avatar"))
    ]

    local_candidates = [
      sender && (Map.get(sender, :avatar) || Map.get(sender, "avatar")),
      local_user && (Map.get(local_user, :avatar) || Map.get(local_user, "avatar"))
    ]

    Enum.find_value(remote_candidates, &normalize_remote_reply_avatar/1) ||
      Enum.find_value(local_candidates, &normalize_local_reply_avatar/1)
  end

  def get_reply_avatar_url(_), do: nil

  @doc """
  Gets the content from a reply.
  Handles both Lemmy API maps and local Message structs.
  """
  @spec get_reply_content(map() | Message.t()) :: String.t()
  def get_reply_content(%Message{content: content}) when is_binary(content), do: content
  def get_reply_content(%{content: content}) when is_binary(content), do: content
  def get_reply_content(%{"content" => content}) when is_binary(content), do: content
  def get_reply_content(_), do: ""

  @doc """
  Gets the score/like count from a reply.
  Handles both Lemmy API maps and local Message structs.
  """
  @spec get_reply_score(map() | Message.t()) :: integer() | nil
  def get_reply_score(%Message{} = msg) do
    msg.score || msg.like_count
  end

  def get_reply_score(%{score: score}) when is_integer(score), do: score
  def get_reply_score(%{like_count: count}) when is_integer(count), do: count
  def get_reply_score(%{"score" => score}) when is_integer(score), do: score
  def get_reply_score(%{"like_count" => count}) when is_integer(count), do: count
  def get_reply_score(_), do: nil

  @doc """
  Returns the normalized community actor URI for a post, or nil if missing/invalid.
  """
  @spec community_actor_uri(map()) :: String.t() | nil
  def community_actor_uri(post) do
    metadata = Map.get(post, :media_metadata)

    if is_map(metadata) do
      metadata
      |> get_community_uri_value()
      |> normalize_community_uri()
    else
      nil
    end
  end

  @doc """
  Checks if a post has a valid community actor URI (indicating a community/Lemmy-style post).
  """
  @spec has_community_uri?(map()) :: boolean()
  def has_community_uri?(post), do: not is_nil(community_actor_uri(post))

  @doc """
  Checks if a post should be treated as a community post.
  Supports both metadata-tagged remote posts and federated posts linked to mirror conversations.
  """
  @spec community_post?(map()) :: boolean()
  def community_post?(post) do
    has_community_uri?(post) || community_conversation_post?(post) ||
      community_post_url_match?(post)
  end

  @doc """
  Checks if a post uses Lemmy-style voting semantics.
  This is narrower than `community_post?/1` because some community posts are
  Mastodon-style posts that should still use like counts instead of vote scores.
  """
  @spec lemmy_vote_post?(map()) :: boolean()
  def lemmy_vote_post?(post) do
    community_post_url_match?(post) || Map.get(post, :post_type) == "discussion" ||
      explicit_vote_totals?(post)
  end

  @doc """
  Determines if a post is a reply based on reply_to_id or inReplyTo metadata.
  """
  @spec reply?(map()) :: boolean()
  def reply?(post) do
    post.reply_to_id != nil ||
      (is_map(post.media_metadata) && post.media_metadata["inReplyTo"] != nil)
  end

  @doc """
  Determines if a post is a gallery post (has images, not video/audio).
  """
  @spec gallery_post?(map()) :: boolean()
  def gallery_post?(post) do
    has_images =
      !Enum.empty?(post.media_urls || []) &&
        Enum.any?(post.media_urls || [], fn url ->
          !String.match?(url, ~r/\.(mp4|webm|ogv|mov|mp3|wav|ogg|m4a)(\?.*)?$/i)
        end)

    post.post_type == "gallery" || has_images
  end

  @doc """
  Calculates display counts for a post, using Lemmy counts if available.
  """
  @spec get_display_counts(map(), map(), map()) :: {integer(), integer()}
  def get_display_counts(post, lemmy_counts, post_replies) do
    post_lemmy_counts = Map.get(lemmy_counts, post.activitypub_id)
    loaded_replies = Map.get(post_replies, post.id, [])
    display_like_count = display_primary_count(post, post_lemmy_counts)
    display_comment_count = display_reply_count(post, post_lemmy_counts, loaded_replies)

    {display_like_count || 0, display_comment_count || 0}
  end

  @doc """
  Returns the visible reply/comment count for a post.
  """
  @spec display_reply_count(map(), map() | nil, list()) :: integer()
  def display_reply_count(post, post_counts \\ nil, loaded_replies \\ []) do
    cached_reply_count = cached_reply_count(post)
    loaded_count = if is_list(loaded_replies), do: length(loaded_replies), else: 0

    cond do
      is_map(post_counts) && is_integer(Map.get(post_counts, :comments)) ->
        Enum.max([loaded_count, Map.get(post_counts, :comments), cached_reply_count])

      is_map(post_counts) && is_integer(Map.get(post_counts, "comments")) ->
        Enum.max([loaded_count, Map.get(post_counts, "comments"), cached_reply_count])

      loaded_count > 0 ->
        max(loaded_count, cached_reply_count)

      true ->
        cached_reply_count
    end
  end

  defp cached_reply_count(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata") || %{}

    [
      parse_non_negative_count(Map.get(post, :reply_count) || Map.get(post, "reply_count")),
      parse_non_negative_count(
        Map.get(post, :remote_reply_count) || Map.get(post, "remote_reply_count")
      ),
      parse_non_negative_count(metadata["original_reply_count"]),
      parse_non_negative_count(metadata["reply_count"]),
      parse_non_negative_count(metadata["replies_count"]),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "replies"])),
      extract_count_from_collection(Map.get(post, :replies) || Map.get(post, "replies")),
      extract_count_from_collection(Map.get(post, :comments) || Map.get(post, "comments")),
      extract_count_from_collection(metadata["replies"]),
      extract_count_from_collection(metadata["comments"])
    ]
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  Returns the visible primary engagement count for a post.

  Vote-style posts prefer explicit upvote/downvote totals when available.
  Like-style posts keep using like counts, with score only as a final fallback.
  """
  @spec display_primary_count(map(), map() | nil) :: integer()
  def display_primary_count(post, post_counts \\ nil) do
    cached_like_count = cached_like_count(post)

    cond do
      lemmy_vote_post?(post) && vote_counts_available?(post_counts) ->
        net_vote_count(post_counts)

      lemmy_vote_post?(post) && vote_counts_available?(post) ->
        net_vote_count(post)

      is_map(post_counts) && is_integer(post_counts.score) && post_counts.score != 0 ->
        post_counts.score

      cached_like_count > 0 ->
        cached_like_count

      is_integer(Map.get(post, :like_count)) && post.like_count > 0 ->
        post.like_count

      is_integer(Map.get(post, :score)) && post.score != 0 ->
        post.score

      is_integer(Map.get(post, :like_count)) ->
        post.like_count

      is_integer(Map.get(post, :score)) ->
        post.score

      true ->
        0
    end
  end

  defp cached_like_count(post) when is_map(post) do
    metadata =
      case Map.get(post, :media_metadata) || Map.get(post, "media_metadata") do
        %{} = metadata -> metadata
        _ -> %{}
      end

    [
      parse_non_negative_count(Map.get(post, :like_count) || Map.get(post, "like_count")),
      parse_non_negative_count(
        Map.get(post, :remote_like_count) || Map.get(post, "remote_like_count")
      ),
      parse_non_negative_count(metadata["original_like_count"]),
      parse_non_negative_count(metadata["like_count"]),
      parse_non_negative_count(metadata["likes_count"]),
      parse_non_negative_count(metadata["favourites_count"]),
      parse_non_negative_count(metadata["favorites_count"]),
      parse_non_negative_count(metadata["favourite_count"]),
      parse_non_negative_count(metadata["favorite_count"]),
      parse_non_negative_count(metadata["reaction_count"]),
      parse_non_negative_count(metadata["reactionCount"]),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "likes"])),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "favourites"])),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "favorites"])),
      parse_non_negative_count(get_in(metadata, ["misskey", "reactionCount"])),
      parse_non_negative_count(get_in(metadata, ["misskey", "reaction_count"])),
      parse_non_negative_count(get_in(metadata, ["pleroma", "favourites_count"])),
      extract_count_from_collection(Map.get(post, :likes) || Map.get(post, "likes")),
      extract_count_from_collection(Map.get(post, :favourites) || Map.get(post, "favourites")),
      extract_count_from_collection(Map.get(post, :favorites) || Map.get(post, "favorites")),
      extract_count_from_collection(metadata["likes"]),
      extract_count_from_collection(metadata["favourites"]),
      extract_count_from_collection(metadata["favorites"])
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp cached_like_count(_), do: 0

  @doc """
  Returns the visible share/repost/boost count for a post.
  """
  @spec display_share_count(map()) :: integer()
  def display_share_count(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata") || %{}

    [
      parse_non_negative_count(Map.get(post, :share_count) || Map.get(post, "share_count")),
      parse_non_negative_count(
        Map.get(post, :remote_share_count) || Map.get(post, "remote_share_count")
      ),
      parse_non_negative_count(metadata["original_share_count"]),
      parse_non_negative_count(metadata["share_count"]),
      parse_non_negative_count(metadata["shares_count"]),
      parse_non_negative_count(metadata["reblogs_count"]),
      parse_non_negative_count(metadata["reblog_count"]),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "shares"])),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "reblogs"])),
      extract_count_from_collection(Map.get(post, :shares) || Map.get(post, "shares")),
      extract_count_from_collection(Map.get(post, :sharesCount) || Map.get(post, "sharesCount")),
      extract_count_from_collection(
        Map.get(post, :announcesCount) || Map.get(post, "announcesCount")
      ),
      extract_count_from_collection(metadata["shares"]),
      extract_count_from_collection(metadata["reblogs"])
    ]
    |> Enum.max(fn -> 0 end)
  end

  def display_share_count(_), do: 0

  @doc """
  Returns where the displayed engagement count came from.

  Remote posts can carry a remote baseline plus local interactions after import. When the visible
  count is greater than the remote baseline, it is treated as mixed.
  """
  @spec engagement_count_source(map(), :like | :reply | :share | :quote) ::
          :none | :local | :remote | :mixed
  def engagement_count_source(post, kind) when is_map(post) do
    remote_count = remote_count_for_source(post, kind)
    display_count = display_count_for_source(post, kind)

    cond do
      display_count <= 0 ->
        :none

      remote_count > 0 and display_count > remote_count ->
        :mixed

      remote_count > 0 ->
        :remote

      true ->
        :local
    end
  end

  def engagement_count_source(_, _), do: :none

  defp display_count_for_source(post, :like), do: display_primary_count(post)
  defp display_count_for_source(post, :reply), do: display_reply_count(post)
  defp display_count_for_source(post, :share), do: display_share_count(post)

  defp display_count_for_source(post, :quote) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata") || %{}

    [
      parse_non_negative_count(Map.get(post, :quote_count) || Map.get(post, "quote_count")),
      parse_non_negative_count(
        Map.get(post, :remote_quote_count) || Map.get(post, "remote_quote_count")
      ),
      parse_non_negative_count(metadata["quotes_count"]),
      parse_non_negative_count(metadata["quote_count"]),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "quotes"]))
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp display_count_for_source(_, _), do: 0

  defp remote_count_for_source(post, :like) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata") || %{}

    [
      parse_non_negative_count(
        Map.get(post, :remote_like_count) || Map.get(post, "remote_like_count")
      ),
      parse_non_negative_count(metadata["original_like_count"]),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "likes"])),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "favourites"])),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "favorites"]))
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp remote_count_for_source(post, :reply) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata") || %{}

    [
      parse_non_negative_count(
        Map.get(post, :remote_reply_count) || Map.get(post, "remote_reply_count")
      ),
      parse_non_negative_count(metadata["original_reply_count"]),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "replies"]))
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp remote_count_for_source(post, :share) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata") || %{}

    [
      parse_non_negative_count(
        Map.get(post, :remote_share_count) || Map.get(post, "remote_share_count")
      ),
      parse_non_negative_count(metadata["original_share_count"]),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "shares"])),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "reblogs"]))
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp remote_count_for_source(post, :quote) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata") || %{}

    [
      parse_non_negative_count(
        Map.get(post, :remote_quote_count) || Map.get(post, "remote_quote_count")
      ),
      parse_non_negative_count(metadata["quotes_count"]),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "quotes"]))
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp remote_count_for_source(_, _), do: 0

  defp vote_counts_available?(counts) when is_map(counts) do
    non_zero_integer?(Map.get(counts, :upvotes)) || non_zero_integer?(Map.get(counts, :downvotes))
  end

  defp vote_counts_available?(_), do: false

  defp net_vote_count(counts) when is_map(counts) do
    (Map.get(counts, :upvotes) || 0) - (Map.get(counts, :downvotes) || 0)
  end

  defp explicit_vote_totals?(post) when is_map(post) do
    non_zero_integer?(Map.get(post, :upvotes) || Map.get(post, "upvotes")) ||
      non_zero_integer?(Map.get(post, :downvotes) || Map.get(post, "downvotes"))
  end

  defp non_zero_integer?(value) when is_integer(value), do: value != 0
  defp non_zero_integer?(_), do: false

  defp parse_non_negative_count(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count >= 0 -> count
      _ -> 0
    end
  end

  defp parse_non_negative_count(_), do: 0

  defp extract_count_from_collection(collection) when is_integer(collection),
    do: max(collection, 0)

  defp extract_count_from_collection(collection) when is_map(collection) do
    parse_non_negative_count(
      Map.get(collection, "totalItems") || Map.get(collection, :totalItems) ||
        Map.get(collection, "total_items") || Map.get(collection, :total_items)
    )
  end

  defp extract_count_from_collection(collection) when is_binary(collection),
    do: parse_non_negative_count(collection)

  defp extract_count_from_collection(_), do: 0

  defp maybe_render_custom_emojis(text, instance_domain) when is_binary(text) do
    if contains_emoji_shortcode?(text) do
      HtmlHelpers.render_custom_emojis(text, instance_domain)
    else
      text
    end
  end

  defp maybe_render_custom_emojis(text, _instance_domain), do: text

  defp contains_emoji_shortcode?(text) when is_binary(text) do
    String.match?(text, ~r/:([a-zA-Z_][a-zA-Z0-9_]*):/)
  end

  defp normalize_remote_reply_avatar(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Elektrine.Strings.present?(trimmed), do: safe_image_url(trimmed)
  end

  defp normalize_remote_reply_avatar(_), do: nil

  defp normalize_local_reply_avatar(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Elektrine.Strings.present?(trimmed), do: Uploads.avatar_url(trimmed)
  end

  defp normalize_local_reply_avatar(_), do: nil

  defp remote_actor_domain(%{remote_actor: remote_actor}), do: remote_actor_domain(remote_actor)

  defp remote_actor_domain(%{domain: domain}) when is_binary(domain),
    do: if(Elektrine.Strings.present?(domain), do: domain, else: nil)

  defp remote_actor_domain(%{"domain" => domain}) when is_binary(domain),
    do: if(Elektrine.Strings.present?(domain), do: domain, else: nil)

  defp remote_actor_domain(_), do: nil

  defp host_from_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) ->
        if(Elektrine.Strings.present?(host), do: host, else: nil)

      _ ->
        nil
    end
  end

  defp host_from_uri(_), do: nil

  defp get_community_uri_value(metadata) do
    metadata["community_actor_uri"] || metadata[:community_actor_uri]
  end

  defp community_conversation_post?(%{
         conversation: %{type: "community"}
       }),
       do: true

  defp community_conversation_post?(%{conversation: %Ecto.Association.NotLoaded{}}), do: false
  defp community_conversation_post?(_), do: false

  defp community_post_url_match?(post) when is_map(post) do
    activitypub_id = Map.get(post, :activitypub_id) || Map.get(post, "activitypub_id")
    activitypub_url = Map.get(post, :activitypub_url) || Map.get(post, "activitypub_url")

    (is_binary(activitypub_id) && LemmyApi.community_post_url?(activitypub_id)) ||
      (is_binary(activitypub_url) && LemmyApi.community_post_url?(activitypub_url))
  end

  defp community_post_url_match?(_), do: false

  defp normalize_community_uri(value) when is_binary(value) do
    normalized = String.trim(value)

    cond do
      normalized == "" ->
        nil

      MapSet.member?(@public_audience_uris, normalized) ->
        nil

      collection_uri?(normalized) ->
        nil

      user_actor_uri?(normalized) ->
        nil

      not community_path_uri?(normalized) ->
        nil

      true ->
        normalized
    end
  end

  defp normalize_community_uri(_), do: nil

  defp collection_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) ->
        normalized = path |> String.downcase() |> String.trim_trailing("/")
        String.ends_with?(normalized, "/followers") || String.ends_with?(normalized, "/following")

      _ ->
        false
    end
  end

  defp collection_uri?(_), do: false

  defp community_path_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) ->
        path_downcased = String.downcase(path)

        Enum.any?(@community_path_markers, &String.contains?(path_downcased, &1))

      _ ->
        false
    end
  end

  defp community_path_uri?(_), do: false

  defp user_actor_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) ->
        downcased_path = String.downcase(path)
        Enum.any?(@user_actor_path_markers, &String.contains?(downcased_path, &1))

      _ ->
        false
    end
  end

  defp user_actor_uri?(_), do: false
end
