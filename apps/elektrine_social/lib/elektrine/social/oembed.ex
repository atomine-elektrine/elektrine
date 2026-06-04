defmodule Elektrine.Social.OEmbed do
  @moduledoc """
  OEmbed discovery and parsing for rich media embeds.

  Supports:
  - OEmbed discovery via link tags in HTML
  - OEmbed API calls to provider endpoints
  - Common providers with hardcoded endpoints

  ## Usage

      case Elektrine.Social.OEmbed.fetch(url) do
        {:ok, oembed} -> 
          # oembed.html contains embeddable HTML
          # oembed.title, oembed.author_name, etc.
        {:error, reason} ->
          # No OEmbed support or fetch failed
      end
  """

  alias Elektrine.HTTP.SafeFetch

  require Logger

  @known_providers [
    {"youtube.com", "/watch", "https://www.youtube.com/oembed"},
    {"youtu.be", nil, "https://www.youtube.com/oembed"},
    {"vimeo.com", nil, "https://vimeo.com/api/oembed.json"},
    {"twitter.com", nil, "https://publish.twitter.com/oembed"},
    {"x.com", nil, "https://publish.twitter.com/oembed"},
    {"open.spotify.com", nil, "https://open.spotify.com/oembed"},
    {"soundcloud.com", nil, "https://soundcloud.com/oembed"},
    {"tiktok.com", nil, "https://www.tiktok.com/oembed"},
    {"instagram.com", nil, "https://api.instagram.com/oembed"},
    {"imgur.com", nil, "https://api.imgur.com/oembed"},
    {"codepen.io", nil, "https://codepen.io/api/oembed"},
    {"reddit.com", nil, "https://www.reddit.com/oembed"}
  ]

  @type oembed :: %{
          type: String.t(),
          version: String.t(),
          title: String.t() | nil,
          author_name: String.t() | nil,
          author_url: String.t() | nil,
          provider_name: String.t() | nil,
          provider_url: String.t() | nil,
          html: String.t() | nil,
          width: integer() | nil,
          height: integer() | nil,
          thumbnail_url: String.t() | nil,
          thumbnail_width: integer() | nil,
          thumbnail_height: integer() | nil
        }

  @doc """
  Fetches OEmbed data for a URL.
  First tries known providers, then falls back to discovery.
  """
  @spec fetch(String.t()) :: {:ok, oembed()} | {:error, atom()}
  def fetch(url) do
    case find_provider(url) do
      {:ok, endpoint} ->
        fetch_from_endpoint(endpoint, url)

      :not_found ->
        discover_and_fetch(url)
    end
  end

  @doc """
  Checks if a URL is from a known OEmbed provider.
  """
  def known_provider?(url) do
    case URI.parse(url) do
      %URI{} = uri -> Enum.any?(@known_providers, &provider_match?(uri, &1))
      _ -> false
    end
  end

  # Private functions

  defp find_provider(url) do
    uri = URI.parse(url)

    Enum.find_value(@known_providers, :not_found, fn provider ->
      if provider_match?(uri, provider) do
        {_, _, endpoint} = provider
        {:ok, endpoint}
      else
        nil
      end
    end)
  end

  defp provider_match?(%URI{host: host, path: path}, {provider_host, required_path, _endpoint})
       when is_binary(host) do
    host = String.downcase(host)
    path = path || "/"

    provider_host?(host, provider_host) and provider_path?(path, required_path)
  end

  defp provider_match?(_, _), do: false

  defp provider_host?(host, provider_host) do
    host == provider_host or String.ends_with?(host, ".#{provider_host}")
  end

  defp provider_path?(_path, nil), do: true
  defp provider_path?(path, required_path), do: String.starts_with?(path, required_path)

  defp fetch_from_endpoint(endpoint, url) do
    encoded_url = URI.encode_www_form(url)
    oembed_url = "#{endpoint}?url=#{encoded_url}&format=json"

    case http_get(oembed_url) do
      {:ok, body} ->
        parse_oembed(body)

      {:error, reason} ->
        Logger.debug("OEmbed fetch failed for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp discover_and_fetch(url) do
    case http_get(url) do
      {:ok, html} ->
        case discover_oembed_link(html) do
          {:ok, oembed_url} ->
            case http_get(oembed_url) do
              {:ok, body} -> parse_oembed(body)
              error -> error
            end

          :not_found ->
            {:error, :no_oembed}
        end

      error ->
        error
    end
  end

  defp discover_oembed_link(html) do
    # Look for <link rel="alternate" type="application/json+oembed" href="...">
    # or <link rel="alternate" type="text/json+oembed" href="...">
    json_pattern =
      ~r/<link[^>]*rel=["']alternate["'][^>]*type=["']application\/json\+oembed["'][^>]*href=["']([^"']+)["']/i

    json_pattern2 =
      ~r/<link[^>]*href=["']([^"']+)["'][^>]*type=["']application\/json\+oembed["']/i

    cond do
      match = Regex.run(json_pattern, html) ->
        {:ok, Enum.at(match, 1)}

      match = Regex.run(json_pattern2, html) ->
        {:ok, Enum.at(match, 1)}

      true ->
        :not_found
    end
  end

  defp parse_oembed(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} ->
        oembed = %{
          type: data["type"],
          version: data["version"] || "1.0",
          title: data["title"],
          author_name: data["author_name"],
          author_url: data["author_url"],
          provider_name: data["provider_name"],
          provider_url: data["provider_url"],
          html: sanitize_html(data["html"]),
          width: data["width"],
          height: data["height"],
          thumbnail_url: data["thumbnail_url"],
          thumbnail_width: data["thumbnail_width"],
          thumbnail_height: data["thumbnail_height"]
        }

        {:ok, oembed}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp http_get(url) do
    # SSRF protection: validate URL before fetching
    case Elektrine.Security.URLValidator.validate(url) do
      :ok ->
        headers = [
          {"user-agent", "Elektrine/1.0 OEmbed (+#{ElektrineWeb.Endpoint.url()})"},
          {"accept", "application/json, text/html"}
        ]

        request = Finch.build(:get, url, headers)

        case SafeFetch.request(request, Elektrine.Finch,
               receive_timeout: 10_000,
               max_body_bytes: 1_000_000
             ) do
          {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
            {:ok, body}

          {:ok, %Finch.Response{status: status}} ->
            {:error, {:http_error, status}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("SSRF protection blocked URL: #{url} - #{reason}")
        {:error, {:ssrf_blocked, reason}}
    end
  end

  # Basic HTML sanitization for OEmbed HTML
  # Only allows iframes from trusted sources
  defp sanitize_html(nil), do: nil

  defp sanitize_html(html) when is_binary(html) do
    # Check if it's an iframe and from a trusted source
    if String.contains?(html, "<iframe") do
      if safe_iframe?(html) do
        html
      else
        nil
      end
    else
      # For other HTML (like Twitter cards), strip scripts
      html
      |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
      |> String.replace(~r/\s*on\w+\s*=\s*["'][^"']*["']/i, "")
    end
  end

  defp safe_iframe?(html) do
    trusted_domains = [
      "youtube.com",
      "youtube-nocookie.com",
      "vimeo.com",
      "player.vimeo.com",
      "open.spotify.com",
      "soundcloud.com",
      "w.soundcloud.com",
      "platform.twitter.com",
      "tiktok.com",
      "codepen.io"
    ]

    # Extract src from iframe
    case Regex.run(~r/src=["']([^"']+)["']/i, html) do
      [_, src] ->
        uri = URI.parse(src)
        host = uri.host || ""

        Enum.any?(trusted_domains, fn domain ->
          host == domain || String.ends_with?(host, "." <> domain)
        end)

      nil ->
        false
    end
  end
end
