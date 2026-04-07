defmodule ElektrineWeb.Plugs.SecurityHeadersTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ElektrineWeb.Plugs.SecurityHeaders

  test "omits unsafe eval and keeps connect-src explicit" do
    conn =
      conn(:get, "/")
      |> Map.put(:scheme, :https)
      |> Map.put(:host, "example.com")
      |> Map.update!(:req_headers, fn headers -> [{"host", "example.com"} | headers] end)

    conn = SecurityHeaders.call(conn, [])

    [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")

    refute String.contains?(csp, "'unsafe-eval'")

    assert String.contains?(
             csp,
             "connect-src 'self' ws://example.com wss://example.com https://challenges.cloudflare.com https://static.cloudflareinsights.com https://cloud.umami.is https://api-gateway.umami.dev"
           )

    refute String.contains?(
             csp,
             "connect-src 'self' ws://example.com wss://example.com https://challenges.cloudflare.com https:;"
           )
  end
end
