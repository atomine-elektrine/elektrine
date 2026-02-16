defmodule ElektrineWeb.Components.Social.PostUtilities do
  @moduledoc """
  Shared utility functions for post rendering components.
  Provides common functionality for TimelinePost, LemmyPost, and other post components.
  """

  alias Elektrine.Messaging.Message
  alias ElektrineWeb.HtmlHelpers

  @public_audience_uris MapSet.new([
                          "Public",
                          "as:Public",
                          "https://www.w3.org/ns/activitystreams#Public"
                        ])

  @doc """
  Checks if the given URL is a video file based on extension.
  """
  @spec is_video_url?(String.t() | nil) :: boolean()
  def is_video_url?(url) when is_binary(url) do
    String.match?(String.downcase(url), ~r/\.(mp4|webm|ogv|mov)(\?.*)?$/)
  end

  def is_video_url?(_), do: false

  @doc """
  Checks if the given URL is an audio file based on extension.
  """
  @spec is_audio_url?(String.t() | nil) :: boolean()
  def is_audio_url?(url) when is_binary(url) do
    String.match?(String.downcase(url), ~r/\.(mp3|wav|m4a|aac|flac|oga|opus|ogg)(\?.*)?$/)
  end

  def is_audio_url?(_), do: false

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
    cond do
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
    |> HtmlSanitizeEx.strip_tags()
    |> String.slice(0, 200)
    |> HtmlHelpers.escape_html()
    |> HtmlHelpers.convert_emoji_shortcodes()
    |> maybe_render_custom_emojis(instance_domain)
  end

  def render_content_preview(_, _instance_domain), do: ""

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
    |> Kernel.||(host_from_uri(Map.get(item, :activitypub_url) || Map.get(item, "activitypub_url")))
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

  def get_reply_author(%{remote_actor: %{username: username, domain: domain}}) do
    "@#{username}@#{domain}"
  end

  def get_reply_author(%{remote_actor: %{username: username}}) do
    "@#{username}"
  end

  def get_reply_author(%{sender: %{username: username}}) do
    "@#{username}"
  end

  def get_reply_author(_), do: ""

  @doc """
  Gets the content from a reply.
  Handles both Lemmy API maps and local Message structs.
  """
  @spec get_reply_content(map() | Message.t()) :: String.t()
  def get_reply_content(%Message{content: content}) when is_binary(content), do: content
  def get_reply_content(%{content: content}) when is_binary(content), do: content
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
  Determines if a post is a reply based on reply_to_id or inReplyTo metadata.
  """
  @spec is_reply?(map()) :: boolean()
  def is_reply?(post) do
    post.reply_to_id != nil ||
      (is_map(post.media_metadata) && post.media_metadata["inReplyTo"] != nil)
  end

  @doc """
  Determines if a post is a gallery post (has images, not video/audio).
  """
  @spec is_gallery_post?(map()) :: boolean()
  def is_gallery_post?(post) do
    has_images =
      !Enum.empty?(post.media_urls || []) &&
        Enum.any?(post.media_urls || [], fn url ->
          !String.match?(url, ~r/\.(mp4|webm|ogv|mov|mp3|wav|ogg|m4a)(\?.*)?$/i)
        end)

    post.post_type == "gallery" || has_images
  end

  @doc """
  Determines the appropriate click event for a post.
  """
  @spec get_post_click_event(map()) :: String.t()
  def get_post_click_event(post) do
    if post.federated && post.activitypub_id,
      do: "navigate_to_remote_post",
      else: "navigate_to_post"
  end

  @doc """
  Calculates display counts for a post, using Lemmy counts if available.
  """
  @spec get_display_counts(map(), map(), map()) :: {integer(), integer()}
  def get_display_counts(post, lemmy_counts, post_replies) do
    post_lemmy_counts = Map.get(lemmy_counts, post.activitypub_id)
    loaded_replies = Map.get(post_replies, post.id, [])

    display_like_count =
      if post_lemmy_counts, do: post_lemmy_counts.score, else: post.like_count || 0

    display_comment_count =
      cond do
        post_lemmy_counts -> max(length(loaded_replies), post_lemmy_counts.comments)
        loaded_replies != [] -> max(length(loaded_replies), post.reply_count || 0)
        true -> post.reply_count || 0
      end

    {display_like_count || 0, display_comment_count || 0}
  end

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

  defp remote_actor_domain(%{remote_actor: remote_actor}), do: remote_actor_domain(remote_actor)

  defp remote_actor_domain(%{domain: domain}) when is_binary(domain) and domain != "", do: domain
  defp remote_actor_domain(%{"domain" => domain}) when is_binary(domain) and domain != "", do: domain
  defp remote_actor_domain(_), do: nil

  defp host_from_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp host_from_uri(_), do: nil

  defp get_community_uri_value(metadata) do
    metadata["community_actor_uri"] || metadata[:community_actor_uri]
  end

  defp normalize_community_uri(value) when is_binary(value) do
    normalized = String.trim(value)

    cond do
      normalized == "" ->
        nil

      MapSet.member?(@public_audience_uris, normalized) ->
        nil

      true ->
        normalized
    end
  end

  defp normalize_community_uri(_), do: nil
end
