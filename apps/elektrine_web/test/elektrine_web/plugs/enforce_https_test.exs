defmodule ElektrineWeb.Plugs.EnforceHTTPSTest do
  use ElektrineWeb.ConnCase, async: false

  alias ElektrineWeb.Plugs.EnforceHTTPS

  setup do
    previous_enforce_https = Application.get_env(:elektrine, :enforce_https)

    Application.put_env(:elektrine, :enforce_https, true)

    on_exit(fn ->
      Application.put_env(:elektrine, :enforce_https, previous_enforce_https)
    end)

    :ok
  end

  test "redirects plain-http custom domains to the same host", %{conn: conn} do
    conn =
      conn
      |> Map.put(:scheme, :http)
      |> Map.put(:host, "maxfieldluke.com")
      |> Map.put(:request_path, "/")
      |> Map.put(:query_string, "")
      |> EnforceHTTPS.call([])

    assert conn.status == 308
    assert get_resp_header(conn, "location") == ["https://maxfieldluke.com/"]
  end

  test "keeps query strings when redirecting to https", %{conn: conn} do
    conn =
      conn
      |> Map.put(:scheme, :http)
      |> Map.put(:host, "maxfieldluke.com")
      |> Map.put(:request_path, "/posts")
      |> Map.put(:query_string, "page=2")
      |> EnforceHTTPS.call([])

    assert conn.status == 308
    assert get_resp_header(conn, "location") == ["https://maxfieldluke.com/posts?page=2"]
  end
end
