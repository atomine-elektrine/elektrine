defmodule ElektrineWeb.AutoconfigController do
  @moduledoc """
  Serves email client autodiscovery configuration.

  Supports:
  - Mozilla Autoconfig (Thunderbird, Apple Mail, etc.)
  - Microsoft Autodiscover (Outlook)
  """
  use ElektrineWeb, :controller

  alias Elektrine.Domains

  @doc """
  Mozilla Autoconfig format for Thunderbird, Apple Mail, etc.
  GET /.well-known/autoconfig/mail/config-v1.1.xml
  GET /mail/config-v1.1.xml (for autoconfig.domain.com)
  """
  def mozilla_autoconfig(conn, _params) do
    domain = get_domain(conn)
    xml_domain = xml_escape(domain)
    xml_mail_host = xml_escape(mail_service_host(domain))

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <clientConfig version="1.1">
      <emailProvider id="#{xml_domain}">
        <domain>#{xml_domain}</domain>
        <displayName>Elektrine Mail</displayName>
        <displayShortName>Elektrine</displayShortName>

        <incomingServer type="imap">
          <hostname>#{xml_mail_host}</hostname>
          <port>993</port>
          <socketType>SSL</socketType>
          <authentication>password-cleartext</authentication>
          <username>%EMAILADDRESS%</username>
        </incomingServer>

        <outgoingServer type="smtp">
          <hostname>#{xml_mail_host}</hostname>
          <port>587</port>
          <socketType>STARTTLS</socketType>
          <authentication>password-cleartext</authentication>
          <username>%EMAILADDRESS%</username>
        </outgoingServer>
      </emailProvider>
    </clientConfig>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, xml)
  end

  @doc """
  Microsoft Autodiscover for Outlook.
  POST /autodiscover/autodiscover.xml
  """
  def microsoft_autodiscover(conn, _params) do
    # Parse email from request body
    {:ok, body, conn} = read_body(conn)
    email = sanitize_email(extract_email_from_autodiscover(body))
    domain = get_domain(conn)
    xml_mail_host = xml_escape(mail_service_host(domain))
    xml_email = xml_escape(email)

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/responseschema/2006">
      <Response xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a">
        <Account>
          <AccountType>email</AccountType>
          <Action>settings</Action>
          <Protocol>
            <Type>IMAP</Type>
            <Server>#{xml_mail_host}</Server>
            <Port>993</Port>
            <SSL>on</SSL>
            <AuthRequired>on</AuthRequired>
            <LoginName>#{xml_email}</LoginName>
          </Protocol>
          <Protocol>
            <Type>SMTP</Type>
            <Server>#{xml_mail_host}</Server>
            <Port>587</Port>
            <SSL>off</SSL>
            <AuthRequired>on</AuthRequired>
            <LoginName>#{xml_email}</LoginName>
            <Encryption>TLS</Encryption>
          </Protocol>
        </Account>
      </Response>
    </Autodiscover>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, xml)
  end

  @doc """
  Apple Mail mobileconfig profile.
  GET /.well-known/apple-app-site-association is handled elsewhere.
  This provides a downloadable .mobileconfig for iOS/macOS.
  """
  def apple_mobileconfig(conn, params) do
    email = sanitize_email(params["email"] || "")
    username = sanitize_username(params["username"] || List.first(String.split(email, "@")) || "")
    domain = get_domain(conn)
    mail_host = mail_service_host(domain)
    uuid1 = Ecto.UUID.generate()
    uuid2 = Ecto.UUID.generate()
    uuid3 = Ecto.UUID.generate()

    plist_email = xml_escape(email)
    plist_username = xml_escape(username)
    plist_mail_host = xml_escape(mail_host)

    # Mobileconfig is a plist XML format
    plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>PayloadContent</key>
      <array>
        <dict>
          <key>EmailAccountDescription</key>
          <string>Elektrine Mail</string>
          <key>EmailAccountName</key>
          <string>#{plist_username}</string>
          <key>EmailAccountType</key>
          <string>EmailTypeIMAP</string>
          <key>EmailAddress</key>
          <string>#{plist_email}</string>
          <key>IncomingMailServerAuthentication</key>
          <string>EmailAuthPassword</string>
          <key>IncomingMailServerHostName</key>
          <string>#{plist_mail_host}</string>
          <key>IncomingMailServerPortNumber</key>
          <integer>993</integer>
          <key>IncomingMailServerUseSSL</key>
          <true/>
          <key>IncomingMailServerUsername</key>
          <string>#{plist_email}</string>
          <key>OutgoingMailServerAuthentication</key>
          <string>EmailAuthPassword</string>
          <key>OutgoingMailServerHostName</key>
          <string>#{plist_mail_host}</string>
          <key>OutgoingMailServerPortNumber</key>
          <integer>465</integer>
          <key>OutgoingMailServerUseSSL</key>
          <true/>
          <key>OutgoingMailServerUsername</key>
          <string>#{plist_email}</string>
          <key>OutgoingPasswordSameAsIncomingPassword</key>
          <true/>
          <key>PayloadDescription</key>
          <string>Configures Elektrine email account</string>
          <key>PayloadDisplayName</key>
          <string>Elektrine Mail</string>
          <key>PayloadIdentifier</key>
          <string>com.elektrine.mail.account.#{uuid2}</string>
          <key>PayloadType</key>
          <string>com.apple.mail.managed</string>
          <key>PayloadUUID</key>
          <string>#{uuid2}</string>
          <key>PayloadVersion</key>
          <integer>1</integer>
        </dict>
      </array>
      <key>PayloadDescription</key>
      <string>Elektrine Mail Configuration</string>
      <key>PayloadDisplayName</key>
      <string>Elektrine Mail</string>
      <key>PayloadIdentifier</key>
      <string>com.elektrine.mail.#{uuid1}</string>
      <key>PayloadOrganization</key>
      <string>Elektrine</string>
      <key>PayloadRemovalDisallowed</key>
      <false/>
      <key>PayloadType</key>
      <string>Configuration</string>
      <key>PayloadUUID</key>
      <string>#{uuid3}</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
    </plist>
    """

    conn
    |> put_resp_content_type("application/x-apple-aspen-config")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"elektrine-mail.mobileconfig\""
    )
    |> send_resp(200, plist)
  end

  defp get_domain(conn) do
    host = conn.host || Domains.primary_email_domain()

    host
    |> String.downcase()
    |> String.replace(~r/^autoconfig\./, "")
    |> String.replace(~r/^autodiscover\./, "")
    |> then(fn domain ->
      if Domains.local_email_domain?(domain), do: domain, else: Domains.primary_email_domain()
    end)
  end

  defp extract_email_from_autodiscover(body) do
    case Regex.run(~r/<EMailAddress>([^<]+)<\/EMailAddress>/i, body) do
      [_, email] -> email
      _ -> ""
    end
  end
  defp mail_service_host(domain) when is_binary(domain) do
    "mail.#{domain}"
  end

  defp sanitize_email(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/u, value) do
      value
    else
      ""
    end
  end

  defp sanitize_email(_), do: ""

  defp sanitize_username(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^[:alnum:]_.+\- ]/u, "")
    |> String.slice(0, 128)
  end

  defp sanitize_username(_), do: ""

  defp xml_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp xml_escape(value), do: value |> to_string() |> xml_escape()
end
