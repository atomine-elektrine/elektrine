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
    ] ++ aliases(domain, ttl)
  end

  defp aliases(domain, ttl) do
    for {key, label} <- [
          {"mail", "Mail host alias"},
          {"imap", "IMAP alias"},
          {"pop", "POP alias"},
          {"smtp", "SMTP alias"},
          {"mta-sts", "MTA-STS policy host"},
          {"autoconfig", "Mail autoconfig alias"},
          {"autodiscover", "Mail autodiscover alias"}
        ] do
      %{
        managed_key: "mail:#{key}",
        name: key,
        type: "CNAME",
        ttl: ttl,
        content: domain,
        required: false,
        metadata: %{"label" => label}
      }
    end
  end
end
