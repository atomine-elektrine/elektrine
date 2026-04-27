defmodule ElektrineWeb.Plugs.SecurityHeadersTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ElektrineWeb.Plugs.SecurityHeaders

  test "omits unsafe eval, nonces scripts, and keeps connect-src explicit" do
    conn =
      conn(:get, "/")
      |> Map.put(:scheme, :https)
      |> Map.put(:host, "example.com")
      |> Map.update!(:req_headers, fn headers -> [{"host", "example.com"} | headers] end)

    conn = SecurityHeaders.call(conn, [])

    [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")

    refute String.contains?(csp, "'unsafe-eval'")
    assert csp =~ ~r/script-src 'self' 'nonce-[^']+'/
    refute csp =~ ~r/script-src[^;]*'unsafe-inline'/

    assert csp =~
             ~r/connect-src 'self' ws:\/\/(localhost|example\.com) wss:\/\/(localhost|example\.com) https:\/\/challenges\.cloudflare\.com/

    refute csp =~ ~r/connect-src[^;]*https:;/
  end
end
