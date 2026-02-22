defmodule Elektrine.TextHelpers do
  @moduledoc """
  Shared helper functions for text processing, sanitization, and formatting.
  """

  @doc """
  Truncates text to a maximum length, adding "..." if truncated.

  ## Examples

      iex> TextHelpers.truncate("Hello world", 5)
      "Hello..."

      iex> TextHelpers.truncate("Hi", 10)
      "Hi"

      iex> TextHelpers.truncate(nil, 10)
      ""
  """
  def truncate(nil, _max_length), do: ""
  def truncate("", _max_length), do: ""

  def truncate(text, max_length) when is_binary(text) and is_integer(max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "..."
    else
      text
    end
  end

  def truncate(text, _), do: to_string(text)

  @doc """
  Sanitizes a search term for safe use in SQL LIKE queries.

  Escapes special characters: %, _, and \\

  ## Examples

      iex> TextHelpers.sanitize_search_term("hello%world")
      "hello\\\\%world"
  """
  def sanitize_search_term(term) when is_binary(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  def sanitize_search_term(_), do: ""

  @doc """
  Strips HTML tags from text, leaving plain text content.

  This is a simple implementation - use specialized functions for
  complex HTML processing (e.g., preserving links, handling entities).

  ## Options
    - `:decode_entities` - whether to decode HTML entities (default: true)
    - `:normalize_whitespace` - whether to collapse multiple spaces (default: true)
  """
  def strip_html(nil), do: nil
  def strip_html(""), do: ""

  def strip_html(html, opts \\ []) when is_binary(html) do
    decode_entities = Keyword.get(opts, :decode_entities, true)
    normalize_ws = Keyword.get(opts, :normalize_whitespace, true)

    result =
      html
      |> String.replace(~r/<script[^>]*>.*?<\/script>/is, " ")
      |> String.replace(~r/<style[^>]*>.*?<\/style>/is, " ")
      |> String.replace(~r/<br\s*\/?>/, "\n")
      |> String.replace(~r/<\/p>/, "\n")
      |> String.replace(~r/<[^>]+>/, " ")

    result =
      if decode_entities do
        decode_html_entities(result)
      else
        result
      end

    if normalize_ws do
      result
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    else
      String.trim(result)
    end
  end

  @doc """
  Decodes common HTML entities to their character equivalents.
  """
  def decode_html_entities(text) when is_binary(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&ndash;", "-")
    |> String.replace("&mdash;", "-")
    |> String.replace("&hellip;", "...")
    |> String.replace("&trade;", "TM")
    |> String.replace("&copy;", "(c)")
    |> String.replace("&reg;", "(R)")
    |> String.replace("&ldquo;", "\"")
    |> String.replace("&rdquo;", "\"")
    |> String.replace("&lsquo;", "'")
    |> String.replace("&rsquo;", "'")
    |> String.replace("&bull;", "*")
    |> String.replace("&middot;", "*")
  end

  def decode_html_entities(text), do: text

  @doc """
  Extracts domain from a URL string.

  ## Examples

      iex> TextHelpers.extract_domain_from_url("https://example.com/path")
      "example.com"

      iex> TextHelpers.extract_domain_from_url(nil)
      nil
  """
  def extract_domain_from_url(nil), do: nil
  def extract_domain_from_url(""), do: nil

  def extract_domain_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  @doc """
  Formats a relative time string like "5 minutes ago".

  Returns full words (e.g., "5 minutes") - append " ago" as needed.
  """
  def time_ago_in_words(datetime)

  def time_ago_in_words(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> time_ago_in_words()
  end

  def time_ago_in_words(%DateTime{} = datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff} seconds"
      diff < 3600 -> "#{div(diff, 60)} minutes"
      diff < 86_400 -> "#{div(diff, 3600)} hours"
      diff < 2_592_000 -> "#{div(diff, 86400)} days"
      diff < 31_536_000 -> "#{div(diff, 2_592_000)} months"
      true -> "#{div(diff, 31_536_000)} years"
    end
  end

  def time_ago_in_words(_), do: ""

  @doc """
  Formats a relative time string in abbreviated form.

  Returns abbreviated format (e.g., "5m", "2h", "3d").
  For older content, returns a date string.
  """
  def time_ago_short(datetime)

  def time_ago_short(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> time_ago_short()
  end

  def time_ago_short(%DateTime{} = datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86_400 -> "#{div(diff, 3600)}h"
      diff < 2_592_000 -> "#{div(diff, 86400)}d"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  def time_ago_short(_), do: ""
end
