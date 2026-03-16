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
      nil -> nil
      normalized_domain -> Profiles.get_verified_custom_domain_for_host(normalized_domain)
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
end
