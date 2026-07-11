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
  Returns a signed local proxy URL for remote media regardless of the global
  proxy preference.

  This is intended for privacy-sensitive surfaces such as search thumbnails,
  where the browser must never contact the result host directly. Obvious
  private targets are rejected synchronously; the proxy controller performs
  full DNS and redirect validation again before fetching.
  """
  def signed_url(nil), do: nil
  def signed_url(""), do: nil

  def signed_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: userinfo}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             userinfo in [nil, ""] ->
        cond do
          String.match?(url, ~r/[\x00-\x20\x7F]/u) -> nil
          URLValidator.private_ip?(host) -> nil
          URLValidator.is_private_domain?(host) -> nil
          blocklisted?(url) -> nil
          true -> encode_url(url)
        end

      _uri ->
        nil
    end
  end

  def signed_url(_url), do: nil

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
        # Don't proxy blocked URLs, they'll return 404.
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

    runtime_banned?(url) or
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
  Returns true when a remote media URL recently failed proxy fetching.
  """
  def failed?(url) when is_binary(url), do: Elektrine.AppCache.media_proxy_failed?(url)
  def failed?(_url), do: false

  @doc """
  Temporarily suppresses a remote media URL after upstream failures.
  """
  def mark_failed(url, reason) when is_binary(url),
    do: Elektrine.AppCache.mark_media_proxy_failed(url, reason)

  def mark_failed(_url, _reason), do: {:ok, false}

  @doc """
  Invalidates cached proxy failure state for a URL.
  """
  def invalidate(url) when is_binary(url),
    do: Elektrine.AppCache.invalidate_media_proxy_failure(url)

  def invalidate(_url), do: {:ok, false}

  @doc """
  Returns true when a remote media URL has a runtime admin ban.
  """
  def runtime_banned?(url) when is_binary(url), do: Elektrine.AppCache.media_proxy_banned?(url)
  def runtime_banned?(_url), do: false

  @doc """
  Adds a runtime admin ban for a remote media URL.
  """
  def ban(url, reason \\ :admin)

  def ban(url, reason) when is_binary(url) do
    if admin_url_valid?(url) do
      Elektrine.AppCache.ban_media_proxy_url(url, reason)
    else
      {:error, :invalid_url}
    end
  end

  def ban(_url, _reason), do: {:error, :invalid_url}

  @doc """
  Removes a runtime admin ban for a remote media URL.
  """
  def unban(url) when is_binary(url), do: Elektrine.AppCache.unban_media_proxy_url(url)
  def unban(_url), do: {:error, :invalid_url}

  @doc """
  Clears media proxy failure state and optionally bans the URLs.
  """
  def purge(urls, opts \\ [])

  def purge(urls, opts) when is_list(urls) do
    ban? = Keyword.get(opts, :ban, false)

    urls
    |> Enum.map(&purge_one(&1, ban?))
    |> Enum.reduce(%{invalidated: [], banned: [], rejected: []}, fn
      {:invalidated, url}, acc ->
        update_in(acc.invalidated, &[url | &1])

      {:banned, url}, acc ->
        acc |> update_in([:invalidated], &[url | &1]) |> update_in([:banned], &[url | &1])

      {:rejected, url}, acc ->
        update_in(acc.rejected, &[url | &1])
    end)
    |> Map.update!(:invalidated, &Enum.reverse/1)
    |> Map.update!(:banned, &Enum.reverse/1)
    |> Map.update!(:rejected, &Enum.reverse/1)
  end

  def purge(url, opts) when is_binary(url), do: purge([url], opts)
  def purge(_urls, _opts), do: %{invalidated: [], banned: [], rejected: []}

  @doc """
  Lists recent failed media proxy URLs and runtime bans.
  """
  def cache_state(limit \\ 100) do
    %{
      failures: Elektrine.AppCache.list_media_proxy_failures(limit),
      bans: Elektrine.AppCache.list_media_proxy_bans(limit)
    }
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

  defp purge_one(url, ban?) when is_binary(url) do
    if admin_url_valid?(url) do
      invalidate(url)

      if ban? do
        ban(url, :admin_purge)
        {:banned, url}
      else
        {:invalidated, url}
      end
    else
      {:rejected, url}
    end
  end

  defp purge_one(url, _ban?), do: {:rejected, url}

  defp admin_url_valid?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and byte_size(host) > 0 ->
        not URLValidator.private_ip?(host) and not URLValidator.is_private_domain?(host)

      _ ->
        false
    end
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
    secure_compare(signature, expected)
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

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
