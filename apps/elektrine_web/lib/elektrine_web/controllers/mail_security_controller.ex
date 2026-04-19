defmodule ElektrineWeb.MailSecurityController do
  use ElektrineWeb, :controller

  alias Elektrine.Domains

  @dns_module :"Elixir.Elektrine.DNS"
  @mail_security_module :"Elixir.Elektrine.DNS.MailSecurity"

  def mta_sts(conn, _params) do
    case mta_sts_policy(conn.host) do
      {:ok, policy} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(:ok, policy)

      :error ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(:not_found, "not found")
    end
  end

  defp mta_sts_policy(host) do
    case mta_sts_domain(host) do
      domain when is_binary(domain) ->
        case @dns_module.get_zone_by_domain(domain) do
          %{id: zone_id, domain: zone_domain} ->
            case @dns_module.get_zone_service_config(zone_id, "mail") do
              %{enabled: true, settings: settings} ->
                {:ok, @mail_security_module.mta_sts_policy(zone_domain, settings || %{})}

              _ ->
                fallback_mta_sts_policy(domain)
            end

          _ ->
            fallback_mta_sts_policy(domain)
        end

      _ ->
        :error
    end
  end

  defp fallback_mta_sts_policy(domain) do
    if domain in Domains.supported_email_domains() do
      settings = %{"mail_target" => fallback_mail_target(), "mta_sts_mode" => "enforce"}
      {:ok, @mail_security_module.mta_sts_policy(domain, settings)}
    else
      :error
    end
  end

  defp fallback_mail_target do
    Application.get_env(:elektrine, :email, [])
    |> Keyword.get(:custom_domain_mx_host, "mail.#{Domains.primary_email_domain()}")
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
