defmodule Elektrine.ActivityPub.RemoteFetch do
  @moduledoc """
  Central fetch boundary for remote ActivityPub resources.

  This module applies the federation fetch policy before delegating to the low-level
  `Fetcher`: per-domain concurrency/backoff through `DomainThrottler`, HTTP
  rate-limit backoff through `Elektrine.HTTP.Backoff`, and the existing URL/body
  validation in `Fetcher`.
  """

  require Logger

  alias Elektrine.ActivityPub.DomainThrottler
  alias Elektrine.ActivityPub.Fetcher
  alias Elektrine.HTTP.Backoff

  @non_domain_failure_reasons [
    :invalid_activitypub_id,
    :invalid_json,
    :not_found,
    :object_id_mismatch,
    :unsafe_url
  ]

  @doc """
  Fetches a remote ActivityPub object through the centralized fetch policy.
  """
  def fetch_object(uri, opts \\ []) do
    fetch_with_domain_policy(uri, opts, &Fetcher.fetch_object/2)
  end

  @doc """
  Fetches a remote ActivityPub actor through the centralized fetch policy.
  """
  def fetch_actor(uri, opts \\ []) do
    fetch_with_domain_policy(uri, opts, &Fetcher.fetch_actor/2)
  end

  @doc """
  Resolves a WebFinger handle through the centralized fetch policy.
  """
  def webfinger_lookup(acct, opts \\ []) do
    fetch_with_domain_policy(acct, opts, &Fetcher.webfinger_lookup/2, webfinger_domain(acct))
  end

  @doc """
  Fetches a remote ActivityPub object without using the object cache.
  """
  def fetch_object_uncached(uri, opts \\ []) do
    fetch_object(uri, Keyword.put(opts, :skip_cache, true))
  end

  @doc """
  Fetches a single object strictly, bypassing cache and HTML/API recovery.
  """
  def fetch_object_strict(uri, opts \\ []) do
    opts = Keyword.merge([skip_cache: true, allow_recovery: false], opts)
    fetch_object(uri, opts)
  end

  @doc """
  Returns current local health/backoff state for a remote URI or domain.
  """
  def domain_health(uri_or_domain) when is_binary(uri_or_domain) do
    domain = fetch_domain(uri_or_domain) || uri_or_domain

    %{
      domain: domain,
      domain_backoff?: domain_backoff?(domain),
      domain_delay_ms: domain_delay(domain),
      http_backoff_seconds: Backoff.get_backoff_remaining(domain)
    }
  end

  def domain_health(_),
    do: %{domain: nil, domain_backoff?: false, domain_delay_ms: 0, http_backoff_seconds: 0}

  defp fetch_with_domain_policy(resource, opts, fetch_fun, domain_source \\ nil) do
    domain = fetch_domain(domain_source || resource)

    if bypass_domain_policy?(opts) or !is_binary(domain) do
      fetch_fun.(resource, opts)
    else
      with_domain_slot(domain, fn -> fetch_fun.(resource, opts) end)
    end
  end

  defp bypass_domain_policy?(opts) do
    Keyword.get(opts, :bypass_domain_throttler, false) || Keyword.has_key?(opts, :request_fun)
  end

  defp with_domain_slot(domain, fun) when is_function(fun, 0) do
    case acquire_domain_slot(domain) do
      {:ok, _} ->
        try do
          result = fun.()
          release_domain_slot(domain, domain_healthy_result?(result))
          result
        rescue
          exception ->
            release_domain_slot(domain, false)
            reraise exception, __STACKTRACE__
        catch
          kind, reason ->
            release_domain_slot(domain, false)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, :throttled} ->
        Logger.debug("RemoteFetch: domain #{domain} is currently throttled")
        {:error, :domain_throttled}

      {:error, :backoff, delay_ms} ->
        Logger.debug("RemoteFetch: domain #{domain} is in backoff for #{delay_ms}ms")
        {:error, :domain_backoff}
    end
  end

  defp acquire_domain_slot(domain) do
    DomainThrottler.acquire(domain)
  catch
    :exit, _ -> {:ok, :throttler_unavailable}
  end

  defp release_domain_slot(domain, success?) do
    DomainThrottler.release(domain, success?)
  catch
    :exit, _ -> :ok
  end

  defp domain_backoff?(domain) when is_binary(domain) do
    DomainThrottler.in_backoff?(domain)
  catch
    :exit, _ -> false
  end

  defp domain_backoff?(_), do: false

  defp domain_delay(domain) when is_binary(domain) do
    DomainThrottler.get_delay(domain)
  catch
    :exit, _ -> 0
  end

  defp domain_delay(_), do: 0

  defp domain_healthy_result?({:ok, _}), do: true

  defp domain_healthy_result?({:error, reason}) when reason in @non_domain_failure_reasons,
    do: true

  defp domain_healthy_result?(_), do: false

  defp fetch_domain(uri) when is_binary(uri) do
    trimmed = String.trim(uri)

    case URI.parse(trimmed) do
      %URI{host: host} when is_binary(host) and host != "" ->
        String.downcase(host)

      _ ->
        if domain_like?(trimmed), do: String.downcase(trimmed)
    end
  end

  defp fetch_domain(_), do: nil

  defp webfinger_domain(acct) when is_binary(acct) do
    acct
    |> String.trim()
    |> String.trim_leading("acct:")
    |> String.trim_leading("@")
    |> String.trim_leading("!")
    |> String.split("@", parts: 2)
    |> case do
      [_name, domain] when domain != "" -> domain
      _ -> nil
    end
  end

  defp webfinger_domain(_), do: nil

  defp domain_like?(value) do
    String.contains?(value, ".") and not String.contains?(value, "/") and
      not String.contains?(value, "@")
  end
end
