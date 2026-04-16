defmodule ElektrineSocialWeb.Components.Social.PostUtilities do
  @moduledoc """
  Shared utility functions for post rendering components.
  Provides common functionality for TimelinePost, LemmyPost, and other post components.
  """

  alias Elektrine.ActivityPub.LemmyApi
  alias Elektrine.Messaging.Message
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
    Enum.filter(urls, fn url ->
      is_binary(url) &&
        (String.match?(url, ~r/\.(jpe?g|png|gif|webp|svg|bmp|avif)(\?.*)?$/i) ||
           String.match?(
             url,
             ~r/(\/media\/|\/images\/|\/uploads\/|\/pictrs\/|i\.imgur|pbs\.twimg|i\.redd\.it)/i
           ))
    end)
  end

  def filter_image_urls(_), do: []

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
  Detects an external link for Lemmy posts that don't have external_link in metadata.
  Checks activitypub_url vs activitypub_id domain, then falls back to extracting from content.
  """
  @spec detect_external_link(map()) :: String.t() | nil
  def detect_external_link(post) do
    primary_url = Map.get(post, :primary_url)

    cond do
      is_binary(primary_url) and String.trim(primary_url) != "" ->
        String.trim(primary_url)

      # Check metadata first
      is_map(post.media_metadata) && post.media_metadata["external_link"] ->
        post.media_metadata["external_link"]

      # Check activitypub_url vs activitypub_id domain
      is_binary(post.activitypub_url) && is_binary(post.activitypub_id) ->
        url_host = URI.parse(post.activitypub_url).host
        id_host = URI.parse(post.activitypub_id).host

        if url_host && id_host && url_host != id_host do
          post.activitypub_url
        else
          extract_url_from_content(post.content)
        end

      true ->
        extract_url_from_content(post.content)
    end
  end

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

  @doc """
  Renders content preview with HTML stripped, length limited, and emoji decoding.

  Decoding order:
  1. Strip HTML and truncate to preview length
  2. Escape remaining text for safe raw rendering
  3. Convert known shortcode aliases to Unicode
  4. Render custom emojis when shortcode patterns remain
  """
  @spec render_content_preview(String.t() | nil, String.t() | nil) :: String.t()
  def render_content_preview(content, instance_domain \\ nil)
  def render_content_preview(nil, _instance_domain), do: ""

  def render_content_preview(content, instance_domain) when is_binary(content) do
    content
    |> plain_text_preview(200)
    |> HtmlHelpers.escape_html()
    |> HtmlHelpers.convert_emoji_shortcodes()
    |> maybe_render_custom_emojis(instance_domain)
  end

  def render_content_preview(_, _instance_domain), do: ""

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

      {emoji, length(emoji_reactions), users, user_reacted || false}
    end)
    |> Enum.sort_by(fn {_, count, _, _} -> -count end)
  end

  def format_reactions(_, _user_id), do: []

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
        msg.remote_actor.avatar_url

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

    [
      Map.get(reply, :author_avatar),
      Map.get(reply, "author_avatar"),
      Map.get(reply, :avatar_url),
      Map.get(reply, "avatar_url"),
      remote_actor && (Map.get(remote_actor, :avatar_url) || Map.get(remote_actor, "avatar_url")),
      sender && (Map.get(sender, :avatar) || Map.get(sender, "avatar")),
      local_user && (Map.get(local_user, :avatar) || Map.get(local_user, "avatar")),
      lemmy_data &&
        (Map.get(lemmy_data, :creator_avatar) || Map.get(lemmy_data, "creator_avatar"))
    ]
    |> Enum.find_value(&normalize_reply_avatar/1)
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
    community_post_url_match?(post) || post.post_type == "discussion" ||
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
    cached_reply_count = cached_reply_count(post)

    display_like_count = display_primary_count(post, post_lemmy_counts)

    display_comment_count =
      cond do
        post_lemmy_counts ->
          max(length(loaded_replies), post_lemmy_counts.comments || cached_reply_count)

        loaded_replies != [] ->
          max(length(loaded_replies), cached_reply_count)

        true ->
          cached_reply_count
      end

    {display_like_count || 0, display_comment_count || 0}
  end

  defp cached_reply_count(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata") || %{}

    [
      parse_non_negative_count(Map.get(post, :reply_count) || Map.get(post, "reply_count")),
      parse_non_negative_count(metadata["original_reply_count"]),
      parse_non_negative_count(metadata["reply_count"]),
      parse_non_negative_count(metadata["replies_count"]),
      parse_non_negative_count(get_in(metadata, ["remote_engagement", "replies"])),
      extract_count_from_collection(metadata["replies"]),
      extract_count_from_collection(metadata["comments"])
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp cached_reply_count(_), do: 0

  @doc """
  Returns the visible primary engagement count for a post.

  Vote-style posts prefer explicit upvote/downvote totals when available.
  Like-style posts keep using like counts, with score only as a final fallback.
  """
  @spec display_primary_count(map(), map() | nil) :: integer()
  def display_primary_count(post, post_counts \\ nil) do
    cond do
      lemmy_vote_post?(post) && vote_counts_available?(post_counts) ->
        net_vote_count(post_counts)

      lemmy_vote_post?(post) && vote_counts_available?(post) ->
        net_vote_count(post)

      is_map(post_counts) && is_integer(post_counts.score) && post_counts.score != 0 ->
        post_counts.score

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

  defp explicit_vote_totals?(_), do: false

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

  defp contains_emoji_shortcode?(_), do: false

  defp normalize_reply_avatar(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      not Elektrine.Strings.present?(trimmed) ->
        nil

      String.starts_with?(trimmed, "http://") || String.starts_with?(trimmed, "https://") ->
        trimmed

      true ->
        Uploads.avatar_url(trimmed)
    end
  end

  defp normalize_reply_avatar(_), do: nil

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
