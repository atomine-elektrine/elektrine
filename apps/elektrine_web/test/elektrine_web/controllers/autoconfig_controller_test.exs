defmodule ElektrineWeb.AutoconfigControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Domains

  setup do
    previous_imap_host = System.get_env("IMAP_HOST")
    previous_smtp_host = System.get_env("SMTP_HOST")
    previous_mail_service_host = System.get_env("MAIL_SERVICE_HOST")

    on_exit(fn ->
      restore_env("IMAP_HOST", previous_imap_host)
      restore_env("SMTP_HOST", previous_smtp_host)
      restore_env("MAIL_SERVICE_HOST", previous_mail_service_host)
    end)

    :ok
  end

  describe "GET /.well-known/autoconfig/mail/config-v1.1.xml" do
    test "returns IMAP and SMTP service hostnames", %{conn: conn} do
      domain = Domains.primary_email_domain()

      conn =
        conn
        |> Map.put(:host, "autoconfig." <> domain)
        |> get("/.well-known/autoconfig/mail/config-v1.1.xml")

      xml = response(conn, 200)

      assert xml =~ "<domain>#{domain}</domain>"
      assert xml =~ "<hostname>mail.#{domain}</hostname>"
      assert xml =~ "<port>993</port>"
      assert xml =~ "<port>587</port>"
      assert xml =~ "<socketType>SSL</socketType>"
      assert xml =~ "<socketType>STARTTLS</socketType>"
    end
  end

  describe "POST /autodiscover/autodiscover.xml" do
    test "returns IMAP and SMTP service hostnames", %{conn: conn} do
      domain = Domains.primary_email_domain()

      body = """
      <Autodiscover>
        <Request>
          <EMailAddress>user@#{domain}</EMailAddress>
        </Request>
      </Autodiscover>
      """

      conn =
        conn
        |> Map.put(:host, domain)
        |> put_req_header("content-type", "text/xml")
        |> post("/autodiscover/autodiscover.xml", body)

      xml = response(conn, 200)

      assert xml =~ "<Server>mail.#{domain}</Server>"
      assert xml =~ "<Port>993</Port>"
      assert xml =~ "<Port>587</Port>"
      assert xml =~ "<SSL>on</SSL>"
      assert xml =~ "<SSL>off</SSL>"
      assert xml =~ "<Encryption>TLS</Encryption>"
    end
  end

  describe "explicit mail host overrides" do
    test "uses configured IMAP and SMTP hosts", %{conn: conn} do
      System.put_env("IMAP_HOST", "mail.elektrine.com")
      System.put_env("SMTP_HOST", "mail.elektrine.com")

      domain = Domains.primary_email_domain()

      conn =
        conn
        |> Map.put(:host, "autoconfig." <> domain)
        |> get("/.well-known/autoconfig/mail/config-v1.1.xml")

      xml = response(conn, 200)

      assert xml =~ "<hostname>mail.elektrine.com</hostname>"
      refute xml =~ "<hostname>imap.#{domain}</hostname>"
      refute xml =~ "<hostname>smtp.#{domain}</hostname>"
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
