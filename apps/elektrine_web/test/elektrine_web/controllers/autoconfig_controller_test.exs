defmodule ElektrineWeb.AutoconfigControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Domains

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
end
