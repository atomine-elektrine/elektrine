defmodule ElektrineWeb.Plugs.ProfileCustomDomainTest do
  use ElektrineWeb.ConnCase, async: true

  alias ElektrineWeb.Plugs.ProfileCustomDomain

  test "ignores forwarded host headers for custom domain routing" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "internal-server")
      |> Plug.Conn.put_req_header("x-forwarded-host", "verified.example.com")
      |> ProfileCustomDomain.call([])

    refute conn.assigns[:profile_custom_domain]
    refute conn.assigns[:subdomain_handle]
    assert conn.host == "internal-server"
  end
end
