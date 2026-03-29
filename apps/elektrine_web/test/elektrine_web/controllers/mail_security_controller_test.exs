defmodule ElektrineWeb.MailSecurityControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.DNS

  test "serves MTA-STS policy for managed mail zones", %{conn: conn} do
    user = user_fixture()
    domain = "mailpolicy#{System.unique_integer([:positive])}.example.com"

    {:ok, zone} = DNS.create_zone(user, %{"domain" => domain})

    assert {:ok, _config} =
             DNS.apply_zone_service(zone, "mail", %{
               "settings" => %{
                 "mail_target" => "mx.#{domain}",
                 "mta_sts_mode" => "testing",
                 "tls_rpt_rua" => "mailto:tls@#{domain}"
               }
             })

    conn =
      conn
      |> Map.put(:host, "mta-sts.#{domain}")
      |> get("/.well-known/mta-sts.txt")

    assert response(conn, 200) =~
             "version: STSv1\nmode: testing\nmx: mx.#{domain}\nmax_age: 86400\n"

    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end
end
