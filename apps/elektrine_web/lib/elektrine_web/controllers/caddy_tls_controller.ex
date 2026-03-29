defmodule ElektrineWeb.CaddyTLSController do
  use ElektrineWeb, :controller

  alias Elektrine.Profiles

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
        if built_in_domain?(normalized_domain) do
          normalized_domain
        else
          Profiles.get_verified_custom_domain_for_host(normalized_domain)
        end
    end
  end

  defp allowed_domain(_), do: nil

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
    email_supported_domains =
      Application.get_env(:elektrine, :email, [])
      |> Keyword.get(:supported_domains, [])

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
        ["www." <> to_string(Application.get_env(:elektrine, :primary_domain, ""))]

    profile_base_domains = Application.get_env(:elektrine, :profile_base_domains, [])

    host in Enum.reject(exact_domains, &is_nil/1) or
      Enum.any?(profile_base_domains, fn base_domain ->
        base_domain = to_string(base_domain)
        String.ends_with?(host, "." <> base_domain)
      end)
  end
end
