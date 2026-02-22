defmodule ElektrineWeb.HtmlHelpers do
  @moduledoc ~s|Centralized HTML helper functions for safe content rendering.\n\nCRITICAL: Always escape user input BEFORE processing to prevent XSS attacks.\nNever use raw() without first escaping user content.\n"""  @doc ~s"""Safely converts user content to HTML with clickable links and hashtags.\n\nSECURITY: This function ALWAYS escapes user input first to prevent XSS,\nthen processes URLs and hashtags on the already-escaped content.\n\n## Examples\n\n    iex> make_content_safe_with_links(\"<script>alert('XSS')</script>\")\n    \"&lt;script&gt;alert(&#39;XSS&#39;)&lt;/script&gt;\"\n\n    iex> make_content_safe_with_links(\"Check out https://example.com\")\n    \"Check out <a href=\"https://example.com\" ...>https://example.com</a>\"\n|
  def make_content_safe_with_links(nil) do
    ""
  end

  def make_content_safe_with_links("") do
    ""
  end

  def make_content_safe_with_links(content) when is_binary(content) do
    content |> escape_html() |> process_tokens()
  end

  def make_links_and_hashtags_clickable(content) do
    make_content_safe_with_links(content)
  end

  @doc ~s|Renders post content appropriately based on whether it's a local or federated post.\n\nFor federated posts (with remote_actor), uses render_remote_post_content which:\n- Rewrites hashtag links to local /hashtag/ paths\n- Rewrites mention links to local /remote/ paths\n- Renders custom emojis from the remote instance\n\nFor local posts, uses make_content_safe_with_links.\n\n## Examples\n\n    iex> render_post_content(%{content: \"Hello #world\", remote_actor: nil})\n    # Uses make_content_safe_with_links\n\n    iex> render_post_content(%{content: \"Hello #world\", remote_actor: %{domain: \"mastodon.social\"}})\n    # Uses render_remote_post_content with proper hashtag rewriting\n|
  def render_post_content(post) do
    content = post.content

    cond do
      is_nil(content) || content == "" ->
        ""

      Ecto.assoc_loaded?(post.remote_actor) && post.remote_actor != nil ->
        render_remote_post_content(content, post.remote_actor.domain)

      true ->
        content
        |> make_content_safe_with_links()
        |> render_custom_emojis()
        |> preserve_line_breaks()
    end
  end

  defp process_tokens(escaped_text) do
    escaped_text
    |> String.split(~r/(\s+)/, include_captures: true)
    |> Enum.map(fn token ->
      cond do
        String.match?(token, ~r/^\s+$/) ->
          token

        String.match?(token, ~r/^@\w+@[\w.-]+/) ->
          case Regex.run(~r/^@(\w+)@([\w.-]+)/, token) do
            [match, username, domain] ->
              ~s(<a href="https://#{domain}/@#{username}" target="_blank" rel="noopener noreferrer" class="text-primary hover:underline font-semibold">#{match}</a>)

            _ ->
              token
          end

        String.match?(token, ~r/^https?:\/\//) ->
          clean_url = String.replace(token, ~r/[.!?,;:]$/, "")

          if valid_linkify_url?(clean_url) do
            ~s(<a href="#{clean_url}" target="_blank" rel="noopener noreferrer" class="text-primary hover:underline font-medium">#{clean_url}</a>)
          else
            token
          end

        String.match?(token, ~r/^#\w+/) ->
          hashtag_name = String.slice(token, 1..-1//1)

          ~s(<a href="/hashtag/#{String.downcase(hashtag_name)}" class="text-primary hover:underline font-medium">#{token}</a>)

        String.match?(token, ~r/^@\w+$/) ->
          username = String.slice(token, 1..-1//1)

          ~s(<a href="/#{String.downcase(username)}" class="text-primary hover:underline font-semibold">@#{username}</a>)

        true ->
          token
      end
    end)
    |> Enum.map_join("", & &1)
  end

  @doc ~s|Safely converts user content to HTML with clickable links only (no hashtags).\n|
  def make_content_safe_with_links_only(nil) do
    ""
  end

  def make_content_safe_with_links_only("") do
    ""
  end

  def make_content_safe_with_links_only(content) when is_binary(content) do
    content |> escape_html() |> linkify_urls()
  end

  @doc ~s|Safely escapes HTML entities in user content.\n|
  def escape_html(text) when is_binary(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  def escape_html(_) do
    ""
  end

  @doc ~s|Converts URLs in already-escaped HTML to clickable links.\n\nIMPORTANT: Only call this on already-escaped content!\n|
  def linkify_urls(escaped_html) when is_binary(escaped_html) do
    url_pattern = ~r/(https?:\/\/[^\s&<>]+)/

    Regex.replace(url_pattern, escaped_html, fn url ->
      if String.contains?(escaped_html, ~s(href="#{url}")) do
        url
      else
        clean_url = String.replace(url, ~r/[.!?,;:]$/, "")

        if valid_linkify_url?(clean_url) do
          ~s(<a href="#{clean_url}" target="_blank" rel="noopener noreferrer" class="text-primary hover:underline font-medium">#{clean_url}</a>)
        else
          url
        end
      end
    end)
  end

  def linkify_urls(content) do
    content
  end

  defp valid_linkify_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> true
      _ -> false
    end
  end

  defp valid_linkify_url?(_) do
    false
  end

  @doc ~s|Converts hashtags in already-escaped HTML to clickable links.\n\nIMPORTANT: Only call this on already-escaped content!\n|
  def linkify_hashtags(escaped_html) when is_binary(escaped_html) do
    hashtag_pattern = ~r/(?<!&)(#\w+)(?!\d*;)/

    Regex.replace(hashtag_pattern, escaped_html, fn hashtag ->
      hashtag_name = String.slice(hashtag, 1..-1//1)

      ~s(<a href="/hashtag/#{String.downcase(hashtag_name)}" class="text-primary hover:underline font-medium">#{hashtag}</a>)
    end)
  end

  def linkify_hashtags(content) do
    content
  end

  @doc ~s|Converts @mentions in already-escaped HTML to clickable links.\nHandles both local mentions (@username) and fediverse mentions (@user@domain.com).\n\nIMPORTANT: Only call this on already-escaped content!\n|
  def linkify_local_mentions(escaped_html) when is_binary(escaped_html) do
    Regex.replace(
      ~r/@(\w+)(?!@)/,
      escaped_html,
      fn match, username ->
        if Regex.match?(~r/@#{username}@[\w.-]+/, escaped_html) do
          match
        else
          ~s(<a href="/#{String.downcase(username)}" class="text-primary hover:underline font-semibold">#{match}</a>)
        end
      end
    )
  end

  def linkify_local_mentions(content) do
    content
  end

  def linkify_mentions(content) do
    linkify_local_mentions(content)
  end

  @doc ~s|Adds paragraph formatting to content while preserving links.\nUsed primarily in discussions for better formatting.\n\nIMPORTANT: Only call this on already-escaped and linkified content!\n|
  def format_with_paragraphs(html_content) when is_binary(html_content) do
    html_content
    |> String.split("\n\n")
    |> Enum.map(fn paragraph ->
      paragraph
      |> String.trim()
      |> case do
        "" -> ""
        text -> "<p class=\"mb-4\">#{text}</p>"
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def format_with_paragraphs(content) do
    content
  end

  @doc ~s|Preserves line breaks in content by converting them to HTML breaks and paragraphs.\n- Single line breaks (\n) become <br> tags\n- Double line breaks (\n\n) create paragraph spacing\n\nUsed for timeline posts and other content where line break preservation is important.\n\nIMPORTANT: Only call this on already-escaped and linkified content!\n|
  def preserve_line_breaks(html_content) when is_binary(html_content) do
    html_content
    |> String.split(~r/\n\n+/)
    |> Enum.map(fn paragraph ->
      paragraph
      |> String.trim()
      |> case do
        "" ->
          ""

        text ->
          formatted_text = String.replace(text, "\n", "<br>")
          "<p class=\"mb-4\">#{formatted_text}</p>"
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def preserve_line_breaks(content) do
    content
  end

  @doc ~s|Sanitizes content for safe display in HTML attributes.\nUseful for title attributes, alt text, etc.\n|
  def sanitize_for_attribute(nil) do
    ""
  end

  def sanitize_for_attribute(text) when is_binary(text) do
    text |> String.replace(~r/[<>"']/, "") |> String.slice(0, 200)
  end

  def sanitize_for_attribute(_) do
    ""
  end

  @doc ~s|Truncates text safely for previews while preserving word boundaries.\n|
  def truncate_safely(nil, _) do
    ""
  end

  def truncate_safely("", _) do
    ""
  end

  def truncate_safely(text, max_length) when is_binary(text) and is_integer(max_length) do
    if String.length(text) <= max_length do
      text
    else
      truncated = String.slice(text, 0, max_length)

      case String.split(truncated, ~r/\s+/) |> Enum.reverse() |> tl() |> Enum.reverse() do
        [] -> truncated <> "..."
        words -> Enum.join(words, " ") <> "..."
      end
    end
  end

  def truncate_safely(text, _) do
    text
  end

  @doc ~s|Validates that content doesn't contain dangerous patterns.\nReturns {:ok, content} or {:error, reason}\n\nThis is a defense-in-depth measure - content should still be escaped!\n|
  def validate_safe_content(content) when is_binary(content) do
    dangerous_patterns = [
      ~r/<script/i,
      ~r/on\w+\s*=/i,
      ~r/javascript:/i,
      ~r/data:.*script/i,
      ~r/vbscript:/i,
      ~r/<link/i,
      ~r/<import/i,
      ~r/<object/i,
      ~r/<embed/i,
      ~r/<meta.*http-equiv/i,
      ~r/<base/i,
      ~r/<form/i,
      ~r/<iframe/i
    ]

    if Enum.any?(dangerous_patterns, &Regex.match?(&1, content)) do
      {:error, "Content contains potentially dangerous HTML"}
    else
      {:ok, content}
    end
  end

  def validate_safe_content(_) do
    {:ok, ""}
  end

  @doc ~s|Converts emoji shortcodes to Unicode emojis.\nSafe to use on already-escaped content.\n|
  def convert_emoji_shortcodes(text) when is_binary(text) do
    emoji_map = %{
      ":smile:" => "😊",
      ":heart:" => "❤️",
      ":thumbsup:" => "👍",
      ":thumbsdown:" => "👎",
      ":fire:" => "🔥",
      ":100:" => "💯",
      ":tada:" => "🎉",
      ":rocket:" => "🚀",
      ":eyes:" => "👀",
      ":thinking:" => "🤔"
    }

    Enum.reduce(emoji_map, text, fn {shortcode, emoji}, acc ->
      String.replace(acc, shortcode, emoji)
    end)
  end

  def convert_emoji_shortcodes(text) do
    text
  end

  @doc ~s|Renders custom emojis from federated instances.\nReplaces :shortcode: patterns with img tags.\nSafe to use on already-escaped content.\n\nIMPORTANT: Only call this on already-escaped content!\nOptional instance_domain parameter to filter emojis by instance.\n|
  def render_custom_emojis(text, instance_domain \\ nil)

  def render_custom_emojis(nil, _instance_domain) do
    nil
  end

  def render_custom_emojis("", _instance_domain) do
    ""
  end

  def render_custom_emojis(escaped_html, instance_domain) when is_binary(escaped_html) do
    {processed_content, _emojis} =
      Elektrine.Emojis.render_custom_emojis(escaped_html, instance_domain)

    processed_content
  end

  def render_custom_emojis(content, _instance_domain) do
    content
  end

  @doc ~s|Renders a display name with custom emojis.\nEscapes the display name first, then renders emojis.\nReturns safe HTML.\nOptional instance_domain parameter to filter emojis by instance.\n|
  def render_display_name_with_emojis(display_name, instance_domain \\ nil)

  def render_display_name_with_emojis(nil, _instance_domain) do
    ""
  end

  def render_display_name_with_emojis("", _instance_domain) do
    ""
  end

  def render_display_name_with_emojis(display_name, instance_domain)
      when is_binary(display_name) do
    escaped = escape_html(display_name)
    render_custom_emojis(escaped, instance_domain)
  end

  def render_display_name_with_emojis(_, _instance_domain) do
    ""
  end

  @doc ~s|Ensures a URL uses HTTPS instead of HTTP to prevent mixed content warnings.\nReturns nil if the input is nil.\n\n## Examples\n\n    iex> ensure_https(\"http://example.com/image.png\")\n    \"https://example.com/image.png\"\n\n    iex> ensure_https(\"https://example.com/image.png\")\n    \"https://example.com/image.png\"\n\n    iex> ensure_https(nil)\n    nil\n|
  def ensure_https(nil) do
    nil
  end

  def ensure_https("") do
    ""
  end

  def ensure_https(url) when is_binary(url) do
    if String.starts_with?(url, "http://") do
      String.replace_prefix(url, "http://", "https://")
    else
      url
    end
  end

  def ensure_https(url) do
    url
  end

  @doc ~s|Safely sanitizes HTML using basic_html, with fallback to strip_tags if parsing fails.\n\nUse this instead of calling HtmlSanitizeEx.basic_html() directly in templates,\nas malformed HTML can crash the mochiweb_html parser.\n\n## Examples\n\n    iex> safe_basic_html(\"<p>Hello</p>\")\n    \"<p>Hello</p>\"\n\n    iex> safe_basic_html(\"<malformed with nil attrs>\")\n    \"malformed with nil attrs\"  # Falls back to stripped tags\n|
  def safe_basic_html(nil) do
    ""
  end

  def safe_basic_html("") do
    ""
  end

  def safe_basic_html(html) when is_binary(html) do
    HtmlSanitizeEx.basic_html(html)
  rescue
    _ -> HtmlSanitizeEx.strip_tags(html)
  end

  def safe_basic_html(_) do
    ""
  end

  @doc ~s|Renders a remote actor's bio with sanitization, clickable links, and custom emojis.\n\nThis function:\n1. Sanitizes HTML using HtmlSanitizeEx to allow basic formatting (links, breaks, etc)\n2. Linkifies plain text URLs that weren't already links\n3. Renders custom emojis from the instance\n4. Preserves line breaks\n\n## Examples\n\n    iex> render_remote_bio(\"Check out https://example.com\\nNew line\", \"mastodon.social\")\n    # Returns HTML with clickable link and line break\n|
  def render_remote_bio(nil, _instance_domain) do
    ""
  end

  def render_remote_bio("", _instance_domain) do
    ""
  end

  def render_remote_bio(bio, instance_domain) when is_binary(bio) do
    bio
    |> HtmlSanitizeEx.Scrubber.scrub(ElektrineWeb.Scrubbers.RemoteContent)
    |> render_markdown_images()
    |> linkify_plain_text_urls()
    |> rewrite_mention_links_to_local()
    |> add_link_styles()
    |> render_custom_emojis(instance_domain)
    |> add_paragraph_spacing()
    |> convert_newlines_to_breaks()
  rescue
    _ -> HtmlSanitizeEx.strip_tags(bio)
  end

  def render_remote_bio(_, _instance_domain) do
    ""
  end

  @doc ~s|Renders a federated post's content with sanitization and link rewriting.\n\nThis function:\n1. Sanitizes HTML using HtmlSanitizeEx to allow basic formatting\n2. Rewrites remote hashtag links to local /hashtag/ paths\n3. Rewrites remote mention links to local /remote/ paths\n4. Linkifies plain text URLs that weren't already links\n5. Renders custom emojis from the instance\n\n## Examples\n\n    iex> render_remote_post_content(\"<p>Check out #plushtodon</p>\", \"mastodon.social\")\n    # Returns HTML with local hashtag link\n|
  def render_remote_post_content(nil, _instance_domain) do
    ""
  end

  def render_remote_post_content("", _instance_domain) do
    ""
  end

  def render_remote_post_content(content, instance_domain) when is_binary(content) do
    content
    |> HtmlSanitizeEx.Scrubber.scrub(ElektrineWeb.Scrubbers.RemoteContent)
    |> strip_mastodon_link_spans()
    |> rewrite_hashtag_links_to_local()
    |> rewrite_mention_links_to_local()
    |> linkify_plain_text_urls()
    |> add_link_styles()
    |> render_custom_emojis(instance_domain)
    |> add_paragraph_spacing()
  rescue
    _ -> HtmlSanitizeEx.strip_tags(content)
  end

  def render_remote_post_content(_, _instance_domain) do
    ""
  end

  defp add_paragraph_spacing(html) when is_binary(html) do
    html
    |> String.replace(~r/<p>/i, ~s(<p class="mb-2">))
    |> String.replace(~r/<p class="[^"]*" class="/i, ~s(<p class="))
  end

  defp add_paragraph_spacing(content) do
    content
  end

  defp strip_mastodon_link_spans(html) when is_binary(html) do
    html
    |> String.replace(~r/<span[^>]*class="[^"]*invisible[^"]*"[^>]*>(.*?)<\/span>/is, "\\1")
    |> String.replace(~r/<span[^>]*class="[^"]*ellipsis[^"]*"[^>]*>(.*?)<\/span>/is, "\\1")
  end

  defp strip_mastodon_link_spans(content) do
    content
  end

  defp convert_newlines_to_breaks(html) when is_binary(html) do
    if String.contains?(html, "<p") do
      html |> String.replace(~r/>\s*\n+\s*</, "><")
    else
      String.replace(html, "\n", "<br>")
    end
  end

  defp convert_newlines_to_breaks(content) do
    content
  end

  @doc ~s|Converts markdown image syntax ![alt](url) to HTML img tags.\nOnly allows images from trusted domains (lemmy instances, etc).\nHandles both raw markdown and HTML where markdown wasn't converted.\n|
  def render_markdown_images(html) when is_binary(html) do
    result =
      Regex.replace(
        ~r/!\[([^\]]*)\]\((https?:\/\/[^\s\)]+)\)/,
        html,
        fn _, alt, url -> render_image_tag(alt, url) end
      )

    Regex.replace(
      ~r/<p>!\[([^\]]*)\]\((https?:\/\/[^\s\)]+)\)<\/p>/,
      result,
      fn _, alt, url -> render_image_tag(alt, url) end
    )
  end

  def render_markdown_images(html) do
    html
  end

  defp render_image_tag(alt, url) do
    if trusted_image_url?(url) do
      ~s(<img src="#{HtmlEntities.encode(url)}" alt="#{HtmlEntities.encode(alt)}" class="max-w-full rounded-lg my-2" loading="lazy" />)
    else
      ~s(<a href="#{HtmlEntities.encode(url)}" target="_blank" rel="noopener noreferrer" class="text-violet-500 hover:underline">#{if alt == "" do
        "Image"
      else
        HtmlEntities.encode(alt)
      end}</a>)
    end
  end

  defp trusted_image_url?(url) do
    trusted_patterns = [
      ~r/^https?:\/\/[^\/]*lemmy[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*reddthat[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*feddit[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*beehaw[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*hexbear[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*sopuli[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*sh\.itjust\.works\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*programming\.dev\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/i\.(imgur|redd\.it|postimg)/i,
      ~r/^https?:\/\/media\.(tenor|giphy)\.com/i
    ]

    Enum.any?(trusted_patterns, fn pattern -> Regex.match?(pattern, url) end)
  end

  @doc ~s|Linkifies plain text URLs in HTML that aren't already part of anchor tags.\nWorks on sanitized HTML that may already contain some anchor tags.\n\nIMPORTANT: Should be called on already-sanitized HTML!\n|
  def linkify_plain_text_urls(html) when is_binary(html) do
    html
    |> String.split(~r/(<a\s[^>]*>.*?<\/a>|<img\s[^>]*\/?>)/s, include_captures: true)
    |> Enum.map(fn segment ->
      if String.match?(segment, ~r/^<(a|img)\s/i) do
        segment
      else
        Regex.replace(
          ~r/(https?:\/\/[^\s<>"]+)/,
          segment,
          fn _match, url ->
            clean_url = String.replace(url, ~r/[.!?,;:]+$/, "")

            if valid_linkify_url?(clean_url) do
              ~s(<a href="#{clean_url}" target="_blank" rel="noopener noreferrer" class="text-violet-500 hover:text-violet-400 hover:underline decoration-2 underline-offset-2 font-medium transition-all duration-200">#{clean_url}</a>)
            else
              url
            end
          end
        )
      end
    end)
    |> Enum.map_join("", & &1)
  end

  def linkify_plain_text_urls(content) do
    content
  end

  @doc ~s|Styles all anchor tags in HTML with consistent hover effects.\nAdds classes to both existing anchor tags and linkifies plain text URLs.\n\nIMPORTANT: Should be called on already-sanitized HTML!\n|
  def style_profile_links(html) when is_binary(html) do
    html |> linkify_plain_text_urls() |> add_link_styles()
  end

  def style_profile_links(content) do
    content
  end

  @doc ~s|Rewrites remote mention links to local /remote/user@domain paths.\nHandles various ActivityPub mention link formats:\n- https://domain.com/@username\n- https://domain.com/users/username\n- https://domain.com/u/username (Lemmy)\n|
  def rewrite_mention_links_to_local(html) when is_binary(html) do
    html |> rewrite_mention_hrefs() |> linkify_fediverse_mentions()
  end

  def rewrite_mention_links_to_local(content) do
    content
  end

  @doc ~s|Rewrites remote hashtag links to local /hashtag/name paths.\nHandles various ActivityPub hashtag link formats:\n- https://domain.com/tags/hashtag\n- https://domain.com/tag/hashtag\n|
  def rewrite_hashtag_links_to_local(html) when is_binary(html) do
    Regex.replace(
      ~r/<a\s+([^>]*?)href\s*=\s*"https?:\/\/[^"\/]+\/tags?\/([^"?#\/]+)"([^>]*)>([^<]*(?:<[^\/][^>]*>[^<]*<\/[^>]+>)*[^<]*)<\/a>/i,
      html,
      fn _full, before_href, hashtag_name, after_href, content ->
        clean_hashtag = String.downcase(hashtag_name)
        local_path = "/hashtag/#{clean_hashtag}"
        ~s(<a #{before_href}href="#{local_path}"#{after_href}>#{content}</a>)
      end
    )
  end

  def rewrite_hashtag_links_to_local(content) do
    content
  end

  defp rewrite_mention_hrefs(html) do
    Regex.replace(
      ~r/<a\s+[^>]*href\s*=\s*"https?:\/\/([^"\/]+)\/(?:@|users\/|u\/)([^"?#\/]+)[^"]*"[^>]*>([^<]*(?:<[^\/][^>]*>[^<]*<\/[^>]+>)*[^<]*)<\/a>/i,
      html,
      fn _full, domain, username, _content ->
        clean_username = String.replace(username, ~r/[\/].*$/, "")
        local_path = "/remote/#{clean_username}@#{domain}"

        ~s(<a href="#{local_path}" class="text-violet-500 hover:text-violet-400 hover:underline font-medium" phx-click="stop_propagation">@#{clean_username}@#{domain}</a>)
      end
    )
  end

  defp linkify_fediverse_mentions(html) do
    html
    |> String.split(~r/(<a\s[^>]*>.*?<\/a>)/s, include_captures: true)
    |> Enum.map(fn segment ->
      if String.starts_with?(segment, "<a ") do
        segment
      else
        Regex.replace(
          ~r/@([a-zA-Z0-9_]+)@([a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9])/,
          segment,
          fn full, username, domain ->
            "<a href=\"/remote/#{username}@#{domain}\" class=\"text-violet-500 hover:text-violet-400 hover:underline font-medium\" phx-click=\"stop_propagation\">#{full}</a>"
          end
        )
      end
    end)
    |> Enum.map_join("", & &1)
  end

  defp add_link_styles(html) when is_binary(html) do
    Regex.replace(
      ~r/<a\s+([^>]*?)>/i,
      html,
      fn full_match, attrs ->
        style_classes =
          "text-violet-500 hover:text-violet-400 hover:underline decoration-2 underline-offset-2 font-medium transition-all duration-200"

        result =
          if Regex.match?(~r/phx-click\s*=/i, attrs) do
            full_match
          else
            String.replace(full_match, ~r/>$/, " phx-click=\"stop_propagation\">")
          end

        if Regex.match?(~r/class\s*=\s*"/i, attrs) do
          Regex.replace(
            ~r/(class\s*=\s*")([^"]*)/i,
            result,
            fn _, prefix, existing ->
              new_classes =
                String.split(existing)
                |> Kernel.++(String.split(style_classes))
                |> Enum.uniq()
                |> Enum.join(" ")

              "#{prefix}#{new_classes}"
            end
          )
        else
          String.replace(result, ~r/<a\s+/i, ~s(<a class="#{style_classes}" ))
        end
      end
    )
  end

  defp add_link_styles(content) do
    content
  end

  @doc ~s|Transforms an image URL to request a smaller thumbnail version when possible.\nSupports common fediverse media patterns.\n|
  def thumbnail_url(nil, _size) do
    nil
  end

  def thumbnail_url("", _size) do
    ""
  end

  def thumbnail_url(url, size) when is_binary(url) and is_integer(size) do
    cond do
      String.contains?(url, "/pictrs/") ->
        if String.contains?(url, "?") do
          url <> "&thumbnail=#{size}&format=webp"
        else
          url <> "?thumbnail=#{size}&format=webp"
        end

      String.contains?(url, "/media_attachments/") && String.contains?(url, "/original/") ->
        String.replace(url, "/original/", "/small/")

      String.contains?(url, "pixelfed") ->
        if String.contains?(url, "?") do
          url <> "&w=#{size}"
        else
          url <> "?w=#{size}"
        end

      String.match?(url, ~r/i\.imgur\.com\/\w+\.(jpg|jpeg|png|gif|webp)$/i) ->
        String.replace(url, ~r/\.(\w+)$/, "s.\\1")

      String.contains?(url, "imagedelivery.net") ->
        if String.contains?(url, "/public") do
          String.replace(url, "/public", "/w=#{size}")
        else
          url
        end

      true ->
        url
    end
  end

  def thumbnail_url(url, _size) do
    url
  end

  @doc ~s|Build an absolute URL for navigation links on profile pages.\nOn subdomains (e.g., username.z.org), prepends the main domain to ensure\nlinks go to the main site instead of staying on the subdomain.\nOn main domain, returns the path as-is.\n\n## Examples\n\n    # On subdomain (base_url = \"https://z.org\"):\n    profile_url(\"https://z.org\", \"/timeline/post/123\")\n    # => \"https://z.org/timeline/post/123\"\n\n    # On main domain (base_url = \"\"):\n    profile_url(\"\", \"/timeline/post/123\")\n    # => \"/timeline/post/123\"\n|
  def profile_url(base_url, path) when is_binary(base_url) and is_binary(path) do
    base_url <> path
  end

  def profile_url(nil, path) do
    path
  end

  def profile_url(base_url, nil) do
    base_url
  end

  def profile_url(_, _) do
    "/"
  end
end
