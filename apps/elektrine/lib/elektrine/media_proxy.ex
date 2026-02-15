defmodule Elektrine.MediaProxy do
  @moduledoc """
  Media proxy for federated content.

  Proxies remote media through the local instance to:
  - Protect user privacy (hides IPs from remote servers)
  - Enable caching of remote media
  - Provide consistent availability
  - Allow content filtering/blocking

  ## Configuration

      config :elektrine, :media_proxy,
        enabled: true,
        base_url: "https://media.example.com",  # Optional custom domain
        whitelist: ["cdn.example.com"],          # Skip proxy for these domains
        blocklist: ["evil.com"]                  # Block these domains entirely

  ## URL Format

  Proxied URLs have the format:
    /media_proxy/{signature}/{base64_encoded_url}

  The signature prevents URL enumeration attacks.
  """

  require Logger
  alias Elektrine.Security.URLValidator

  @doc """
  Returns whether the media proxy is enabled.
  """
  def enabled? do
    Application.get_env(:elektrine, :media_proxy, [])[:enabled] || false
  end

  @doc """
  Converts a remote media URL to a proxied URL.
  Returns the original URL if proxy is disabled or URL is whitelisted.
  """
  def url(nil), do: nil
  def url(""), do: nil

  def url(url) when is_binary(url) do
    if should_proxy?(url) do
      encode_url(url)
    else
      url
    end
  end

  @doc """
  Converts a list of URLs to proxied URLs.
  """
  def urls(urls) when is_list(urls) do
    Enum.map(urls, &url/1)
  end

  @doc """
  Decodes a proxied URL back to the original URL.
  Returns {:ok, url} or {:error, reason}.
  """
  def decode_url(encoded) do
    with [signature, encoded_url] <- String.split(encoded, "/", parts: 2),
         {:ok, url} <- Base.url_decode64(encoded_url, padding: false),
         true <- verify_signature(url, signature),
         :ok <- URLValidator.validate(url) do
      {:ok, url}
    else
      _ -> {:error, :invalid_url}
    end
  end

  @doc """
  Checks if a URL should be proxied.
  """
  def should_proxy?(url) when is_binary(url) do
    cond do
      !enabled?() ->
        false

      URLValidator.validate(url) != :ok ->
        false

      local_url?(url) ->
        false

      whitelisted?(url) ->
        false

      blocklisted?(url) ->
        # Don't proxy blocked URLs, they'll return 404
        false

      true ->
        true
    end
  end

  @doc """
  Checks if a URL is blocklisted and should return 404.
  """
  def blocklisted?(url) when is_binary(url) do
    blocklist = get_config()[:blocklist] || []

    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        Enum.any?(blocklist, fn pattern ->
          matches_domain?(host, pattern)
        end)

      _ ->
        false
    end
  end

  @doc """
  Returns the proxy base URL.
  """
  def base_url do
    config = get_config()

    config[:base_url] ||
      ElektrineWeb.Endpoint.url() <> "/media_proxy"
  end

  # Private functions

  defp encode_url(url) do
    encoded = Base.url_encode64(url, padding: false)
    signature = sign_url(url)

    "#{base_url()}/#{signature}/#{encoded}"
  end

  defp sign_url(url) do
    secret = get_signing_secret()

    :crypto.mac(:hmac, :sha256, secret, url)
    |> Base.url_encode64(padding: false)
    # Use first 16 chars for shorter URLs
    |> String.slice(0, 16)
  end

  defp verify_signature(url, signature) do
    expected = sign_url(url)
    Plug.Crypto.secure_compare(signature, expected)
  end

  defp get_signing_secret do
    # Use Phoenix secret key base
    Application.get_env(:elektrine, ElektrineWeb.Endpoint)[:secret_key_base]
    # Derive a separate key for media proxy
    |> :erlang.md5()
  end

  defp local_url?(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        local_hosts = [
          URI.parse(ElektrineWeb.Endpoint.url()).host,
          "localhost",
          "127.0.0.1"
        ]

        host in local_hosts

      _ ->
        false
    end
  end

  defp whitelisted?(url) do
    whitelist = get_config()[:whitelist] || []

    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        Enum.any?(whitelist, fn pattern ->
          matches_domain?(host, pattern)
        end)

      _ ->
        false
    end
  end

  defp matches_domain?(host, pattern) when is_binary(host) and is_binary(pattern) do
    host = String.downcase(host)
    pattern = String.downcase(pattern)

    cond do
      # Exact match
      host == pattern ->
        true

      # Wildcard: *.example.com
      String.starts_with?(pattern, "*.") ->
        suffix = String.replace_prefix(pattern, "*", "")
        String.ends_with?(host, suffix)

      true ->
        false
    end
  end

  defp get_config do
    Application.get_env(:elektrine, :media_proxy, [])
  end
end
