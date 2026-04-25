defmodule ElektrineWeb.CaddyTLSController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Domains
  alias Elektrine.Profiles

  @cache_table :caddy_tls_domain_cache
  @allow_cache_ttl_ms :timer.minutes(5)
  @deny_cache_ttl_ms :timer.minutes(15)

  @doc """
  Approves custom hostnames for Caddy on-demand TLS issuance.

  Caddy calls this endpoint with `?domain=` during the TLS handshake. Only
  verified custom profile domains are allowed.
  """
  def allow(conn, %{"domain" => domain}) do
    case allowed_domain(domain) do
      nil ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(:forbidden, "forbidden")

      _custom_domain ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(:ok, "allowed")
    end
  end

  def allow(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(:bad_request, "missing domain")
  end

  defp allowed_domain(domain) when is_binary(domain) do
    domain
    |> normalize_domain()
    |> case do
      nil ->
        nil

      normalized_domain ->
        cached_allowed_domain(normalized_domain)
    end
  end

  defp allowed_domain(_), do: nil

  defp cached_allowed_domain(domain) do
    ensure_cache_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, domain) do
      [{^domain, value, expires_at}] when expires_at > now ->
        value

      _ ->
        value = resolve_allowed_domain(domain)
        ttl = if value, do: @allow_cache_ttl_ms, else: @deny_cache_ttl_ms

        :ets.insert(@cache_table, {domain, value, now + ttl})
        value
    end
  end

  defp resolve_allowed_domain(domain) do
    cond do
      built_in_domain?(domain) ->
        domain

      invalid_nested_built_in_subdomain?(domain) ->
        nil

      true ->
        Profiles.get_verified_custom_domain_for_host(domain)
    end
  end

  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      _table ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp normalize_domain(domain) do
    domain
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
    |> String.split("/", parts: 2)
    |> List.first()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp built_in_domain?(host) do
    email_supported_domains = Domains.supported_email_domains()

    mail_service_hosts =
      email_supported_domains
      |> Enum.flat_map(fn domain ->
        domain = to_string(domain)

        ["mail.", "imap.", "pop.", "smtp.", "mta-sts."]
        |> Enum.map(&(&1 <> domain))
      end)

    exact_domains =
      [Application.get_env(:elektrine, :primary_domain)] ++
        email_supported_domains ++
        mail_service_hosts ++
        ["www." <> Domains.primary_profile_domain()]

    profile_base_domains = Application.get_env(:elektrine, :profile_base_domains, [])

    host in Enum.reject(exact_domains, &is_nil/1) or
      built_in_profile_host?(host, profile_base_domains)
  end

  defp built_in_profile_host?(host, profile_base_domains) do
    Enum.any?(profile_base_domains, fn base_domain ->
      base_domain = to_string(base_domain)

      with true <- String.ends_with?(host, "." <> base_domain),
           suffix = "." <> base_domain,
           handle when handle not in [nil, ""] <-
             host |> String.trim_trailing(suffix) |> String.trim(),
           false <- String.contains?(handle, "."),
           %User{} = user <- Accounts.get_user_by_handle(handle),
           true <- User.built_in_subdomain_hosted_by_platform?(user) do
        true
      else
        _ -> false
      end
    end)
  end

  defp invalid_nested_built_in_subdomain?(host) do
    profile_base_domains = Application.get_env(:elektrine, :profile_base_domains, [])

    Enum.any?(profile_base_domains, fn base_domain ->
      base_domain = to_string(base_domain)

      String.ends_with?(host, "." <> base_domain) and
        host
        |> String.trim_trailing("." <> base_domain)
        |> String.contains?(".")
    end)
  end
end
