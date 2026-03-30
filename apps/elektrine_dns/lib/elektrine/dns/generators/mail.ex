defmodule Elektrine.DNS.Generators.Mail do
  @moduledoc false

  alias Elektrine.DNS.MailSecurity

  def generate(zone, settings \\ %{}) do
    domain = zone.domain
    ttl = zone.default_ttl || 300
    mail_target = MailSecurity.mail_target(domain, settings)
    dmarc_policy = Map.get(settings, "dmarc_policy", "quarantine")
    dkim_selector = Map.get(settings, "dkim_selector", "default")
    dkim_value = Map.get(settings, "dkim_value", "")

    [
      %{
        managed_key: "mail:mx",
        name: "@",
        type: "MX",
        ttl: ttl,
        content: mail_target,
        priority: 10,
        required: true,
        metadata: %{"label" => "Inbound mail exchanger"}
      },
      %{
        managed_key: "mail:spf",
        name: "@",
        type: "TXT",
        ttl: ttl,
        content: "v=spf1 mx ~all",
        required: true,
        metadata: %{"label" => "SPF policy"}
      },
      %{
        managed_key: "mail:dmarc",
        name: "_dmarc",
        type: "TXT",
        ttl: ttl,
        content: "v=DMARC1; p=#{dmarc_policy}; adkim=s; aspf=s",
        required: true,
        metadata: %{"label" => "DMARC policy"}
      },
      %{
        managed_key: "mail:dkim",
        name: "#{dkim_selector}._domainkey",
        type: "TXT",
        ttl: ttl,
        content: dkim_value,
        required: true,
        metadata: %{"label" => "DKIM public key"}
      },
      %{
        managed_key: "mail:mta-sts-txt",
        name: "_mta-sts",
        type: "TXT",
        ttl: ttl,
        content: MailSecurity.mta_sts_txt_value(domain, settings),
        required: false,
        metadata: %{"label" => "MTA-STS policy id"}
      },
      %{
        managed_key: "mail:tls-rpt",
        name: "_smtp._tls",
        type: "TXT",
        ttl: ttl,
        content: MailSecurity.tls_rpt_txt_value(domain, settings),
        required: false,
        metadata: %{"label" => "TLS-RPT reporting policy"}
      }
    ] ++ mail_host_records(zone, mail_target) ++ aliases(domain, ttl, mail_target)
  end

  defp mail_host_records(zone, mail_target) do
    case same_zone_relative_name(zone.domain, mail_target) do
      nil ->
        []

      "@" ->
        []

      relative_name ->
        zone
        |> apex_address_records()
        |> Enum.sort_by(&{&1.type, &1.content})
        |> Enum.with_index()
        |> Enum.map(fn {record, idx} ->
          %{
            managed_key: "mail:host:#{String.downcase(record.type)}:#{idx}",
            name: relative_name,
            type: record.type,
            ttl: record.ttl,
            content: record.content,
            required: true,
            metadata: %{"label" => "Mail exchanger address"}
          }
        end)
    end
  end

  defp aliases(domain, ttl, mail_target) do
    mail_target_relative = same_zone_relative_name(domain, mail_target)

    for {key, label, target} <- [
          {"mail", "Mail host alias", mail_target},
          {"imap", "IMAP alias", mail_target},
          {"pop", "POP alias", mail_target},
          {"smtp", "SMTP alias", mail_target},
          {"mta-sts", "MTA-STS policy host", domain},
          {"autoconfig", "Mail autoconfig alias", mail_target},
          {"autodiscover", "Mail autodiscover alias", mail_target}
        ],
        mail_target_relative != key do
      %{
        managed_key: "mail:#{key}",
        name: key,
        type: "CNAME",
        ttl: ttl,
        content: target,
        required: false,
        metadata: %{"label" => label}
      }
    end
  end

  defp apex_address_records(zone) do
    zone_domain = normalize_name(zone.domain)

    zone.records
    |> List.wrap()
    |> Enum.filter(fn record ->
      record.type in ["A", "AAAA"] and normalize_name(record.name) in ["@", zone_domain]
    end)
  end

  defp same_zone_relative_name(domain, fqdn) do
    normalized_domain = normalize_name(domain)
    normalized_fqdn = normalize_name(fqdn)

    cond do
      normalized_fqdn == normalized_domain ->
        "@"

      String.ends_with?(normalized_fqdn, "." <> normalized_domain) ->
        normalized_fqdn
        |> String.trim_trailing("." <> normalized_domain)
        |> String.trim_trailing(".")

      true ->
        nil
    end
  end

  defp normalize_name(nil), do: nil

  defp normalize_name(name),
    do: name |> String.trim() |> String.downcase() |> String.trim_trailing(".")
end
