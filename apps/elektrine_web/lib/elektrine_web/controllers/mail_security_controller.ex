defmodule ElektrineWeb.MailSecurityController do
  use ElektrineWeb, :controller

  @dns_module :"Elixir.Elektrine.DNS"
  @mail_security_module :"Elixir.Elektrine.DNS.MailSecurity"

  def mta_sts(conn, _params) do
    with domain when is_binary(domain) <- mta_sts_domain(conn.host),
         %{id: zone_id, domain: zone_domain} <- apply(@dns_module, :get_zone_by_domain, [domain]),
         %{enabled: true, settings: settings} <-
           apply(@dns_module, :get_zone_service_config, [zone_id, "mail"]) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(
        :ok,
        apply(@mail_security_module, :mta_sts_policy, [zone_domain, settings || %{}])
      )
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(:not_found, "not found")
    end
  end

  defp mta_sts_domain(host) when is_binary(host) do
    normalized = host |> String.trim() |> String.trim_trailing(".") |> String.downcase()

    case String.split(normalized, ".", parts: 2) do
      ["mta-sts", domain] when domain != "" -> domain
      _ -> nil
    end
  end

  defp mta_sts_domain(_), do: nil
end
