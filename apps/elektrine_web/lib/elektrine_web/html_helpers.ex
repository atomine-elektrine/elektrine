defmodule ElektrineWeb.HtmlHelpers do
  @moduledoc """
  Centralized HTML helper functions for safe content rendering.

  CRITICAL: Always escape user input BEFORE processing to prevent XSS attacks.
  Never use raw() without first escaping user content.
  """

  @doc """
  Safely converts user content to HTML with clickable links and hashtags.

  SECURITY: This function ALWAYS escapes user input first to prevent XSS,
  then processes URLs and hashtags on the already-escaped content.

  ## Examples

      iex> make_content_safe_with_links("<script>alert('XSS')</script>")
      "&lt;script&gt;alert(&#39;XSS&#39;)&lt;/script&gt;"

      iex> make_content_safe_with_links("Check out https://example.com")
      "Check out <a href=\"https://example.com\" ...>https://example.com</a>"
  """
  def make_content_safe_with_links(nil), do: ""
  def make_content_safe_with_links(""), do: ""

  def make_content_safe_with_links(content) when is_binary(content) do
    # Token-based approach: process each word individually
    content
    |> escape_html()
    |> process_tokens()
  end

  # Alias for backwards compatibility
  def make_links_and_hashtags_clickable(content), do: make_content_safe_with_links(content)

  @doc """
  Renders post content appropriately based on whether it's a local or federated post.

  For federated posts (with remote_actor), uses render_remote_post_content which:
  - Rewrites hashtag links to local /hashtag/ paths
  - Rewrites mention links to local /remote/ paths
  - Renders custom emojis from the remote instance

  For local posts, uses make_content_safe_with_links.

  ## Examples

      iex> render_post_content(%{content: "Hello #world", remote_actor: nil})
      # Uses make_content_safe_with_links

      iex> render_post_content(%{content: "Hello #world", remote_actor: %{domain: "mastodon.social"}})
      # Uses render_remote_post_content with proper hashtag rewriting
  """
  def render_post_content(post) do
    content = post.content

    cond do
      is_nil(content) || content == "" ->
        ""

      # Federated post with remote actor - use remote content renderer
      Ecto.assoc_loaded?(post.remote_actor) && post.remote_actor != nil ->
        render_remote_post_content(content, post.remote_actor.domain)

      # Local post - use standard content renderer
      true ->
        content
        |> make_content_safe_with_links()
        |> render_custom_emojis()
        |> preserve_line_breaks()
    end
  end

  defp process_tokens(escaped_text) do
    # Split by whitespace, preserving newlines
    escaped_text
    |> String.split(~r/(\s+)/, include_captures: true)
    |> Enum.map(fn token ->
      cond do
        # Preserve whitespace as-is
        String.match?(token, ~r/^\s+$/) ->
          token

        # Linkify fediverse mentions (@user@domain)
        String.match?(token, ~r/^@\w+@[\w.-]+/) ->
          case Regex.run(~r/^@(\w+)@([\w.-]+)/, token) do
            [match, username, domain] ->
              ~s(<a href="https://#{domain}/@#{username}" target="_blank" rel="noopener noreferrer" class="text-primary hover:underline font-semibold">#{match}</a>)

            _ ->
              token
          end

        # Linkify URLs
        String.match?(token, ~r/^https?:\/\//) ->
          clean_url = String.replace(token, ~r/[.!?,;:]$/, "")

          if valid_linkify_url?(clean_url) do
            ~s(<a href="#{clean_url}" target="_blank" rel="noopener noreferrer" class="text-primary hover:underline font-medium">#{clean_url}</a>)
          else
            token
          end

        # Linkify hashtags
        String.match?(token, ~r/^#\w+/) ->
          hashtag_name = String.slice(token, 1..-1//1)

          ~s(<a href="/hashtag/#{String.downcase(hashtag_name)}" class="text-primary hover:underline font-medium">#{token}</a>)

        # Linkify mentions (@username) - link to local profile, don't assume domain
        # Only local users will have a valid profile page; remote mentions should have been
        # converted to @user@domain format during ingestion
        String.match?(token, ~r/^@\w+$/) ->
          username = String.slice(token, 1..-1//1)

          ~s(<a href="/#{String.downcase(username)}" class="text-primary hover:underline font-semibold">@#{username}</a>)

        # Plain text
        true ->
          token
      end
    end)
    |> Enum.map_join("", & &1)
  end

  @doc """
  Safely converts user content to HTML with clickable links only (no hashtags).
  """
  def make_content_safe_with_links_only(nil), do: ""
  def make_content_safe_with_links_only(""), do: ""

  def make_content_safe_with_links_only(content) when is_binary(content) do
    content
    |> escape_html()
    |> linkify_urls()
  end

  @doc """
  Safely escapes HTML entities in user content.
  """
  def escape_html(text) when is_binary(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  def escape_html(_), do: ""

  @doc """
  Converts URLs in already-escaped HTML to clickable links.

  IMPORTANT: Only call this on already-escaped content!
  """
  def linkify_urls(escaped_html) when is_binary(escaped_html) do
    # Match URLs that are already HTML-escaped
    # This regex works on escaped content where & becomes &amp; etc
    url_pattern = ~r/(https?:\/\/[^\s&<>]+)/

    Regex.replace(url_pattern, escaped_html, fn url ->
      # Skip if this URL is already part of an anchor tag
      if String.contains?(escaped_html, ~s(href="#{url}")) do
        url
      else
        # Remove trailing punctuation that might have been included
        clean_url = String.replace(url, ~r/[.!?,;:]$/, "")

        # Validate URL before creating link (defense in depth)
        if valid_linkify_url?(clean_url) do
          # Create the link - URL is already escaped, but we validate it
          ~s(<a href="#{clean_url}" target="_blank" rel="noopener noreferrer" class="text-primary hover:underline font-medium">#{clean_url}</a>)
        else
          # If URL validation fails, return the original without linkifying
          url
        end
      end
    end)
  end

  def linkify_urls(content), do: content

  # Validates URLs for linkification (prevents javascript: and data: URIs)
  defp valid_linkify_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> true
      _ -> false
    end
  end

  defp valid_linkify_url?(_), do: false

  @doc """
  Converts hashtags in already-escaped HTML to clickable links.

  IMPORTANT: Only call this on already-escaped content!
  """
  def linkify_hashtags(escaped_html) when is_binary(escaped_html) do
    # Match hashtags but NOT HTML entities like &#39; or &#x20;
    # Negative lookbehind to ensure # is not preceded by &
    hashtag_pattern = ~r/(?<!&)(#\w+)(?!\d*;)/

    Regex.replace(hashtag_pattern, escaped_html, fn hashtag ->
      hashtag_name = String.slice(hashtag, 1..-1//1)

      ~s(<a href="/hashtag/#{String.downcase(hashtag_name)}" class="text-primary hover:underline font-medium">#{hashtag}</a>)
    end)
  end

  def linkify_hashtags(content), do: content

  @doc """
  Converts @mentions in already-escaped HTML to clickable links.
  Handles both local mentions (@username) and fediverse mentions (@user@domain.com).

  IMPORTANT: Only call this on already-escaped content!
  """
  # Linkify local mentions (@username) only
  def linkify_local_mentions(escaped_html) when is_binary(escaped_html) do
    # Match @username but NOT if it's part of @username@domain (fediverse mention)
    # Use negative lookahead to skip fediverse mentions
    Regex.replace(
      ~r/@(\w+)(?!@)/,
      escaped_html,
      fn match, username ->
        # Check if this is part of a fediverse mention by looking ahead
        if Regex.match?(~r/@#{username}@[\w.-]+/, escaped_html) do
          # This is part of @user@domain, leave as plain text
          match
        else
          # Regular local mention, linkify it
          ~s(<a href="/#{String.downcase(username)}" class="text-primary hover:underline font-semibold">#{match}</a>)
        end
      end
    )
  end

  def linkify_local_mentions(content), do: content

  # Legacy function for backwards compatibility
  def linkify_mentions(content), do: linkify_local_mentions(content)

  @doc """
  Adds paragraph formatting to content while preserving links.
  Used primarily in discussions for better formatting.

  IMPORTANT: Only call this on already-escaped and linkified content!
  """
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

  def format_with_paragraphs(content), do: content

  @doc """
  Preserves line breaks in content by converting them to HTML breaks and paragraphs.
  - Single line breaks (\n) become <br> tags
  - Double line breaks (\n\n) create paragraph spacing

  Used for timeline posts and other content where line break preservation is important.

  IMPORTANT: Only call this on already-escaped and linkified content!
  """
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
          # Convert single line breaks to <br> tags within paragraphs
          formatted_text = String.replace(text, "\n", "<br>")
          "<p class=\"mb-4\">#{formatted_text}</p>"
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def preserve_line_breaks(content), do: content

  @doc """
  Sanitizes content for safe display in HTML attributes.
  Useful for title attributes, alt text, etc.
  """
  def sanitize_for_attribute(nil), do: ""

  def sanitize_for_attribute(text) when is_binary(text) do
    text
    |> String.replace(~r/[<>"']/, "")
    |> String.slice(0, 200)
  end

  def sanitize_for_attribute(_), do: ""

  @doc """
  Truncates text safely for previews while preserving word boundaries.
  """
  def truncate_safely(nil, _), do: ""
  def truncate_safely("", _), do: ""

  def truncate_safely(text, max_length) when is_binary(text) and is_integer(max_length) do
    if String.length(text) <= max_length do
      text
    else
      # Find the last space before max_length
      truncated = String.slice(text, 0, max_length)

      case String.split(truncated, ~r/\s+/) |> Enum.reverse() |> tl() |> Enum.reverse() do
        [] -> truncated <> "..."
        words -> Enum.join(words, " ") <> "..."
      end
    end
  end

  def truncate_safely(text, _), do: text

  @doc """
  Validates that content doesn't contain dangerous patterns.
  Returns {:ok, content} or {:error, reason}

  This is a defense-in-depth measure - content should still be escaped!
  """
  def validate_safe_content(content) when is_binary(content) do
    dangerous_patterns = [
      # Script tags
      ~r/<script/i,
      # Event handlers
      ~r/on\w+\s*=/i,
      # JavaScript protocol
      ~r/javascript:/i,
      # Data URIs with scripts
      ~r/data:.*script/i,
      # VBScript protocol
      ~r/vbscript:/i,
      # Import/link tags that could load external resources
      ~r/<link/i,
      ~r/<import/i,
      # Object/embed tags
      ~r/<object/i,
      ~r/<embed/i,
      # Meta refresh
      ~r/<meta.*http-equiv/i,
      # Base tag (can change URL context)
      ~r/<base/i,
      # Form tags (phishing risk)
      ~r/<form/i,
      # Iframe (clickjacking risk)
      ~r/<iframe/i
    ]

    if Enum.any?(dangerous_patterns, &Regex.match?(&1, content)) do
      {:error, "Content contains potentially dangerous HTML"}
    else
      {:ok, content}
    end
  end

  def validate_safe_content(_), do: {:ok, ""}

  @doc """
  Converts emoji shortcodes to Unicode emojis.
  Safe to use on already-escaped content.
  """
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
      # Add more as needed
    }

    Enum.reduce(emoji_map, text, fn {shortcode, emoji}, acc ->
      String.replace(acc, shortcode, emoji)
    end)
  end

  def convert_emoji_shortcodes(text), do: text

  @doc """
  Renders custom emojis from federated instances.
  Replaces :shortcode: patterns with img tags.
  Safe to use on already-escaped content.

  IMPORTANT: Only call this on already-escaped content!
  Optional instance_domain parameter to filter emojis by instance.
  """
  def render_custom_emojis(text, instance_domain \\ nil)
  def render_custom_emojis(nil, _instance_domain), do: nil
  def render_custom_emojis("", _instance_domain), do: ""

  def render_custom_emojis(escaped_html, instance_domain) when is_binary(escaped_html) do
    {processed_content, _emojis} =
      Elektrine.Emojis.render_custom_emojis(escaped_html, instance_domain)

    processed_content
  end

  def render_custom_emojis(content, _instance_domain), do: content

  @doc """
  Renders a display name with custom emojis.
  Escapes the display name first, then renders emojis.
  Returns safe HTML.
  Optional instance_domain parameter to filter emojis by instance.
  """
  def render_display_name_with_emojis(display_name, instance_domain \\ nil)
  def render_display_name_with_emojis(nil, _instance_domain), do: ""
  def render_display_name_with_emojis("", _instance_domain), do: ""

  def render_display_name_with_emojis(display_name, instance_domain)
      when is_binary(display_name) do
    # First escape HTML to prevent XSS
    escaped = escape_html(display_name)

    # Then render custom emojis with instance domain filter
    render_custom_emojis(escaped, instance_domain)
  end

  def render_display_name_with_emojis(_, _instance_domain), do: ""

  @doc """
  Ensures a URL uses HTTPS instead of HTTP to prevent mixed content warnings.
  Returns nil if the input is nil.

  ## Examples

      iex> ensure_https("http://example.com/image.png")
      "https://example.com/image.png"

      iex> ensure_https("https://example.com/image.png")
      "https://example.com/image.png"

      iex> ensure_https(nil)
      nil
  """
  def ensure_https(nil), do: nil
  def ensure_https(""), do: ""

  def ensure_https(url) when is_binary(url) do
    if String.starts_with?(url, "http://") do
      String.replace_prefix(url, "http://", "https://")
    else
      url
    end
  end

  def ensure_https(url), do: url

  @doc """
  Safely sanitizes HTML using basic_html, with fallback to strip_tags if parsing fails.

  Use this instead of calling HtmlSanitizeEx.basic_html() directly in templates,
  as malformed HTML can crash the mochiweb_html parser.

  ## Examples

      iex> safe_basic_html("<p>Hello</p>")
      "<p>Hello</p>"

      iex> safe_basic_html("<malformed with nil attrs>")
      "malformed with nil attrs"  # Falls back to stripped tags
  """
  def safe_basic_html(nil), do: ""
  def safe_basic_html(""), do: ""

  def safe_basic_html(html) when is_binary(html) do
    try do
      HtmlSanitizeEx.basic_html(html)
    rescue
      _ -> HtmlSanitizeEx.strip_tags(html)
    end
  end

  def safe_basic_html(_), do: ""

  @doc """
  Renders a remote actor's bio with sanitization, clickable links, and custom emojis.

  This function:
  1. Sanitizes HTML using HtmlSanitizeEx to allow basic formatting (links, breaks, etc)
  2. Linkifies plain text URLs that weren't already links
  3. Renders custom emojis from the instance
  4. Preserves line breaks

  ## Examples

      iex> render_remote_bio("Check out https://example.com\\nNew line", "mastodon.social")
      # Returns HTML with clickable link and line break
  """
  def render_remote_bio(nil, _instance_domain), do: ""
  def render_remote_bio("", _instance_domain), do: ""

  def render_remote_bio(bio, instance_domain) when is_binary(bio) do
    # Wrap in try/rescue to handle malformed HTML that can crash mochiweb_html parser
    try do
      bio
      # Use custom scrubber that allows img tags for embedded images
      |> HtmlSanitizeEx.Scrubber.scrub(ElektrineWeb.Scrubbers.RemoteContent)
      # Also handle raw markdown ![](url) syntax
      |> render_markdown_images()
      |> linkify_plain_text_urls()
      # Rewrite @mentions to local /remote/ paths
      |> rewrite_mention_links_to_local()
      |> add_link_styles()
      |> render_custom_emojis(instance_domain)
      # Add spacing to p tags for proper paragraph rendering
      |> add_paragraph_spacing()
      # Only convert newlines to <br> if content doesn't already have p tags
      |> convert_newlines_to_breaks()
    rescue
      _ -> HtmlSanitizeEx.strip_tags(bio)
    end
  end

  def render_remote_bio(_, _instance_domain), do: ""

  @doc """
  Renders a federated post's content with sanitization and link rewriting.

  This function:
  1. Sanitizes HTML using HtmlSanitizeEx to allow basic formatting
  2. Rewrites remote hashtag links to local /hashtag/ paths
  3. Rewrites remote mention links to local /remote/ paths
  4. Linkifies plain text URLs that weren't already links
  5. Renders custom emojis from the instance

  ## Examples

      iex> render_remote_post_content("<p>Check out #plushtodon</p>", "mastodon.social")
      # Returns HTML with local hashtag link
  """
  def render_remote_post_content(nil, _instance_domain), do: ""
  def render_remote_post_content("", _instance_domain), do: ""

  def render_remote_post_content(content, instance_domain) when is_binary(content) do
    # Wrap in try/rescue to handle malformed HTML that can crash mochiweb_html parser
    try do
      content
      |> HtmlSanitizeEx.Scrubber.scrub(ElektrineWeb.Scrubbers.RemoteContent)
      # Strip Mastodon's invisible/ellipsis spans to show full URLs
      |> strip_mastodon_link_spans()
      # Rewrite hashtag links to local paths
      |> rewrite_hashtag_links_to_local()
      # Rewrite @mentions to local /remote/ paths
      |> rewrite_mention_links_to_local()
      |> linkify_plain_text_urls()
      |> add_link_styles()
      |> render_custom_emojis(instance_domain)
      |> add_paragraph_spacing()
    rescue
      _ -> HtmlSanitizeEx.strip_tags(content)
    end
  end

  def render_remote_post_content(_, _instance_domain), do: ""

  # Add margin classes to p tags for proper spacing
  defp add_paragraph_spacing(html) when is_binary(html) do
    html
    |> String.replace(~r/<p>/i, ~s(<p class="mb-2">))
    # Clean up double class attributes if p already had a class
    |> String.replace(~r/<p class="[^"]*" class="/i, ~s(<p class="))
  end

  defp add_paragraph_spacing(content), do: content

  # Strip Mastodon's invisible/ellipsis spans that truncate URLs
  # Mastodon wraps links like: <span class="invisible">https://</span><span class="ellipsis">domain.com</span><span class="invisible">/path</span>
  # We want to show the full URL text
  defp strip_mastodon_link_spans(html) when is_binary(html) do
    html
    # Remove <span class="invisible">...</span> but keep the content
    |> String.replace(~r/<span[^>]*class="[^"]*invisible[^"]*"[^>]*>(.*?)<\/span>/is, "\\1")
    # Remove <span class="ellipsis">...</span> but keep the content
    |> String.replace(~r/<span[^>]*class="[^"]*ellipsis[^"]*"[^>]*>(.*?)<\/span>/is, "\\1")
  end

  defp strip_mastodon_link_spans(content), do: content

  # Only convert newlines to breaks if content doesn't have p tags
  defp convert_newlines_to_breaks(html) when is_binary(html) do
    if String.contains?(html, "<p") do
      # Content has paragraph tags, don't add extra breaks
      # Just clean up any stray newlines between tags
      html
      |> String.replace(~r/>\s*\n+\s*</, "><")
    else
      # Plain text content, convert newlines to breaks
      String.replace(html, "\n", "<br>")
    end
  end

  defp convert_newlines_to_breaks(content), do: content

  @doc """
  Converts markdown image syntax ![alt](url) to HTML img tags.
  Only allows images from trusted domains (lemmy instances, etc).
  Handles both raw markdown and HTML where markdown wasn't converted.
  """
  def render_markdown_images(html) when is_binary(html) do
    # First, handle raw markdown: ![alt](url)
    result =
      Regex.replace(
        ~r/!\[([^\]]*)\]\((https?:\/\/[^\s\)]+)\)/,
        html,
        fn _, alt, url -> render_image_tag(alt, url) end
      )

    # Also handle cases where content has <p>![](url)</p> wrapping
    Regex.replace(
      ~r/<p>!\[([^\]]*)\]\((https?:\/\/[^\s\)]+)\)<\/p>/,
      result,
      fn _, alt, url -> render_image_tag(alt, url) end
    )
  end

  def render_markdown_images(html), do: html

  defp render_image_tag(alt, url) do
    if trusted_image_url?(url) do
      ~s(<img src="#{HtmlEntities.encode(url)}" alt="#{HtmlEntities.encode(alt)}" class="max-w-full rounded-lg my-2" loading="lazy" />)
    else
      ~s(<a href="#{HtmlEntities.encode(url)}" target="_blank" rel="noopener noreferrer" class="text-violet-500 hover:underline">#{if alt == "", do: "Image", else: HtmlEntities.encode(alt)}</a>)
    end
  end

  defp trusted_image_url?(url) do
    # Allow images from common fediverse image hosts
    trusted_patterns = [
      ~r/^https?:\/\/[^\/]*lemmy[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*reddthat[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*feddit[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*beehaw[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*hexbear[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*sopuli[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*sh\.itjust\.works\/pictrs\/image\//i,
      ~r/^https?:\/\/[^\/]*programming\.dev\/pictrs\/image\//i,
      # Any pictrs image server
      ~r/^https?:\/\/[^\/]*\/pictrs\/image\//i,
      ~r/^https?:\/\/i\.(imgur|redd\.it|postimg)/i,
      ~r/^https?:\/\/media\.(tenor|giphy)\.com/i
    ]

    Enum.any?(trusted_patterns, fn pattern -> Regex.match?(pattern, url) end)
  end

  @doc """
  Linkifies plain text URLs in HTML that aren't already part of anchor tags.
  Works on sanitized HTML that may already contain some anchor tags.

  IMPORTANT: Should be called on already-sanitized HTML!
  """
  def linkify_plain_text_urls(html) when is_binary(html) do
    # Split by anchor tags AND img tags to avoid linkifying URLs inside them
    # This regex captures: <a ...>...</a> and <img ... /> or <img ...>
    html
    |> String.split(~r/(<a\s[^>]*>.*?<\/a>|<img\s[^>]*\/?>)/s, include_captures: true)
    |> Enum.map(fn segment ->
      # Skip anchor tags and img tags - don't linkify URLs inside them
      if String.match?(segment, ~r/^<(a|img)\s/i) do
        segment
      else
        # Linkify plain text URLs in this segment
        Regex.replace(
          ~r/(https?:\/\/[^\s<>"]+)/,
          segment,
          fn _match, url ->
            # Remove trailing punctuation
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

  def linkify_plain_text_urls(content), do: content

  @doc """
  Styles all anchor tags in HTML with consistent hover effects.
  Adds classes to both existing anchor tags and linkifies plain text URLs.

  IMPORTANT: Should be called on already-sanitized HTML!
  """
  def style_profile_links(html) when is_binary(html) do
    html
    |> linkify_plain_text_urls()
    |> add_link_styles()
  end

  def style_profile_links(content), do: content

  @doc """
  Rewrites remote mention links to local /remote/user@domain paths.
  Handles various ActivityPub mention link formats:
  - https://domain.com/@username
  - https://domain.com/users/username
  - https://domain.com/u/username (Lemmy)
  """
  def rewrite_mention_links_to_local(html) when is_binary(html) do
    html
    # First pass: rewrite href attributes in anchor tags that point to user profiles
    # Match href="https://domain.com/@username" or /users/username or /u/username patterns
    |> rewrite_mention_hrefs()
    # Second pass: linkify plain text fediverse mentions (@user@domain)
    |> linkify_fediverse_mentions()
  end

  def rewrite_mention_links_to_local(content), do: content

  @doc """
  Rewrites remote hashtag links to local /hashtag/name paths.
  Handles various ActivityPub hashtag link formats:
  - https://domain.com/tags/hashtag
  - https://domain.com/tag/hashtag
  """
  def rewrite_hashtag_links_to_local(html) when is_binary(html) do
    # Match anchor tags with href pointing to hashtag pages
    # Handles both /tags/name and /tag/name patterns
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

  def rewrite_hashtag_links_to_local(content), do: content

  # Rewrite existing mention anchor tags to local paths AND update visible text to @user@domain
  defp rewrite_mention_hrefs(html) do
    # Match entire anchor tags with href pointing to user profiles
    # Captures: full anchor tag, domain, username, inner content
    Regex.replace(
      ~r/<a\s+[^>]*href\s*=\s*"https?:\/\/([^"\/]+)\/(?:@|users\/|u\/)([^"?#\/]+)[^"]*"[^>]*>([^<]*(?:<[^\/][^>]*>[^<]*<\/[^>]+>)*[^<]*)<\/a>/i,
      html,
      fn _full, domain, username, _content ->
        clean_username = String.replace(username, ~r/[\/].*$/, "")
        local_path = "/remote/#{clean_username}@#{domain}"
        # Replace anchor with full @user@domain format visible text
        ~s(<a href="#{local_path}" class="text-violet-500 hover:text-violet-400 hover:underline font-medium" phx-click="stop_propagation">@#{clean_username}@#{domain}</a>)
      end
    )
  end

  # Linkify plain text @user@domain mentions that aren't already links
  defp linkify_fediverse_mentions(html) do
    # Split by anchor tags to avoid double-linking
    html
    |> String.split(~r/(<a\s[^>]*>.*?<\/a>)/s, include_captures: true)
    |> Enum.map(fn segment ->
      if String.starts_with?(segment, "<a ") do
        # Already a link, leave it alone
        segment
      else
        # Linkify @user@domain patterns
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

  # Add styling classes and click propagation stopping to existing anchor tags
  defp add_link_styles(html) when is_binary(html) do
    # Replace anchor tags to add styling classes and phx-click handler
    # Handles both <a href="..."> and <a class="..." href="...">
    Regex.replace(
      ~r/<a\s+([^>]*?)>/i,
      html,
      fn full_match, attrs ->
        # Define our style classes
        style_classes =
          "text-violet-500 hover:text-violet-400 hover:underline decoration-2 underline-offset-2 font-medium transition-all duration-200"

        # Add phx-click if not already present
        result =
          if Regex.match?(~r/phx-click\s*=/i, attrs) do
            full_match
          else
            String.replace(full_match, ~r/>$/, " phx-click=\"stop_propagation\">")
          end

        if Regex.match?(~r/class\s*=\s*"/i, attrs) do
          # Has class attribute - merge with ours
          Regex.replace(
            ~r/(class\s*=\s*")([^"]*)/i,
            result,
            fn _, prefix, existing ->
              # Merge classes, avoiding duplicates
              new_classes =
                String.split(existing)
                |> Kernel.++(String.split(style_classes))
                |> Enum.uniq()
                |> Enum.join(" ")

              "#{prefix}#{new_classes}"
            end
          )
        else
          # No class attribute - add it
          # Insert class attribute after <a
          String.replace(result, ~r/<a\s+/i, ~s(<a class="#{style_classes}" ))
        end
      end
    )
  end

  defp add_link_styles(content), do: content

  @doc """
  Transforms an image URL to request a smaller thumbnail version when possible.
  Supports common fediverse media patterns.
  """
  def thumbnail_url(nil, _size), do: nil
  def thumbnail_url("", _size), do: ""

  def thumbnail_url(url, size) when is_binary(url) and is_integer(size) do
    cond do
      # Pictrs image server
      String.contains?(url, "/pictrs/") ->
        if String.contains?(url, "?") do
          url <> "&thumbnail=#{size}&format=webp"
        else
          url <> "?thumbnail=#{size}&format=webp"
        end

      # Media attachments with original/small variants
      String.contains?(url, "/media_attachments/") && String.contains?(url, "/original/") ->
        String.replace(url, "/original/", "/small/")

      # Pixelfed-style width parameter
      String.contains?(url, "pixelfed") ->
        if String.contains?(url, "?") do
          url <> "&w=#{size}"
        else
          url <> "?w=#{size}"
        end

      # Imgur - add size suffix before extension (s=small, m=medium, l=large, h=huge)
      String.match?(url, ~r/i\.imgur\.com\/\w+\.(jpg|jpeg|png|gif|webp)$/i) ->
        String.replace(url, ~r/\.(\w+)$/, "s.\\1")

      # Cloudflare Images - supports /width=SIZE
      String.contains?(url, "imagedelivery.net") ->
        if String.contains?(url, "/public") do
          String.replace(url, "/public", "/w=#{size}")
        else
          url
        end

      # Default: return original URL
      true ->
        url
    end
  end

  def thumbnail_url(url, _size), do: url

  @doc """
  Build an absolute URL for navigation links on profile pages.
  On subdomains (e.g., username.z.org), prepends the main domain to ensure
  links go to the main site instead of staying on the subdomain.
  On main domain, returns the path as-is.

  ## Examples

      # On subdomain (base_url = "https://z.org"):
      profile_url("https://z.org", "/timeline/post/123")
      # => "https://z.org/timeline/post/123"

      # On main domain (base_url = ""):
      profile_url("", "/timeline/post/123")
      # => "/timeline/post/123"
  """
  def profile_url(base_url, path) when is_binary(base_url) and is_binary(path) do
    base_url <> path
  end

  def profile_url(nil, path), do: path
  def profile_url(base_url, nil), do: base_url
  def profile_url(_, _), do: "/"
end
