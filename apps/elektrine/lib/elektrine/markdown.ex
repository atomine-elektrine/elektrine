defmodule Elektrine.Markdown do
  @moduledoc """
  Safe markdown processing for profile descriptions.
  Converts markdown to HTML while sanitizing dangerous content.
  """

  @doc """
  Converts markdown text to safe HTML.
  Strips all images and dangerous content.
  """
  def to_html(markdown_text) when is_binary(markdown_text) do
    markdown_text
    |> MDEx.to_html!()
    |> HtmlSanitizeEx.markdown_html()
    |> strip_images()
  end

  def to_html(nil), do: ""

  @doc """
  Strips markdown formatting and returns plain text.
  Useful for previews or when HTML isn't supported.
  """
  def to_text(markdown_text) when is_binary(markdown_text) do
    markdown_text
    # Bold
    |> String.replace(~r/\*\*(.*?)\*\*/, "\\1")
    # Italic
    |> String.replace(~r/\*(.*?)\*/, "\\1")
    # Code
    |> String.replace(~r/`(.*?)`/, "\\1")
    # Links
    |> String.replace(~r/\[(.*?)\]\(.*?\)/, "\\1")
    # Headers
    |> String.replace(~r/#+\s*/, "")
    |> String.trim()
  end

  def to_text(nil), do: ""

  @doc """
  Validates markdown content length and complexity for user-facing feedback.

  SECURITY: This is a UX-only check, NOT a security boundary. Its substring
  blacklist (`<script`, `javascript:`, `data:`, `<img`, ...) is trivially
  bypassable and must never be relied upon to neutralize hostile input. The
  real XSS/sanitization boundary is `to_html/1`, which renders via MDEx and
  then runs the output through the HtmlSanitizeEx allowlist (and `strip_images/1`).
  Do not treat a passing `validate/1` result as "safe to render raw".
  """
  def validate(markdown_text) when is_binary(markdown_text) do
    cond do
      String.length(markdown_text) > 1000 ->
        {:error, "Markdown content too long (max 1000 characters)"}

      String.contains?(markdown_text, ["<script", "javascript:", "data:"]) ->
        {:error, "Dangerous content detected"}

      contains_images?(markdown_text) ->
        {:error, "Images are not allowed in bio"}

      String.contains?(markdown_text, ["<img", "<iframe", "<video", "<audio", "<embed", "<object"]) ->
        {:error, "HTML embeds are not allowed in bio"}

      count_links(markdown_text) > 10 ->
        {:error, "Too many links (max 10)"}

      true ->
        {:ok, markdown_text}
    end
  end

  def validate(nil), do: {:ok, nil}

  # Count markdown links
  defp count_links(text) do
    ~r/\[.*?\]\(.*?\)/
    |> Regex.scan(text)
    |> length()
  end

  # Check for markdown image syntax: ![alt](url)
  defp contains_images?(text) do
    Regex.match?(~r/!\[.*?\]\(.*?\)/, text)
  end

  # Strip all img tags and iframes from HTML
  defp strip_images(html) do
    html
    |> String.replace(~r/<img[^>]*>/i, "")
    |> String.replace(~r/<iframe[^>]*>.*?<\/iframe>/is, "")
    |> String.replace(~r/<video[^>]*>.*?<\/video>/is, "")
    |> String.replace(~r/<audio[^>]*>.*?<\/audio>/is, "")
    |> String.replace(~r/<embed[^>]*>/i, "")
    |> String.replace(~r/<object[^>]*>.*?<\/object>/is, "")
  end
end
