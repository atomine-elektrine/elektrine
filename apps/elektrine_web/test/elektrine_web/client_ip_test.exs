defmodule ElektrineWeb.ClientIPTest do
  use ElektrineWeb.ConnCase, async: false

  alias ElektrineWeb.ClientIP

  describe "client_ip/1" do
    test "uses x-forwarded-for when remote peer is trusted proxy", %{conn: conn} do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["10.0.0.0/8"])

      conn =
        conn
        |> Map.put(:remote_ip, {10, 20, 30, 40})
        |> put_req_header("x-forwarded-for", "203.0.113.9, 10.20.30.40")

      assert ClientIP.client_ip(conn) == "203.0.113.9"
    end

    test "skips private proxy hops at the front of x-forwarded-for when a public IP follows", %{
      conn: conn
    } do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["10.0.0.0/8"])

      conn =
        conn
        |> Map.put(:remote_ip, {10, 20, 30, 40})
        |> put_req_header("x-forwarded-for", "::ffff:172.16.12.162, 203.0.113.9")

      assert ClientIP.client_ip(conn) == "203.0.113.9"
    end

    test "uses public IP from later x-forwarded-for header values", %{conn: conn} do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["10.0.0.0/8"])

      conn =
        conn
        |> Map.put(:remote_ip, {10, 20, 30, 40})
        |> Map.put(:req_headers, [
          {"x-forwarded-for", "172.18.0.12"},
          {"x-forwarded-for", "198.51.100.15"}
        ])

      assert ClientIP.client_ip(conn) == "198.51.100.15"
    end

    test "resolves from trusted socket peer data and x-headers" do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["172.30.0.12/32"])

      headers = [
        {"x-forwarded-for", "172.18.0.12"},
        {"x-forwarded-for", "203.0.113.44"}
      ]

      assert ClientIP.client_ip({172, 30, 0, 12}, headers) == "203.0.113.44"
    end

    test "uses forwarded IP when Docker presents the proxy subnet gateway", %{conn: conn} do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["172.30.0.0/24"])

      conn =
        conn
        |> Map.put(:remote_ip, {172, 30, 0, 1})
        |> put_req_header("x-forwarded-for", "198.51.100.77, 172.30.0.12")

      assert ClientIP.client_ip(conn) == "198.51.100.77"
    end

    test "falls back to the peer IP when a trusted proxy sends no forwarded headers", %{
      conn: conn
    } do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["172.30.0.0/24"])

      conn = Map.put(conn, :remote_ip, {172, 30, 0, 1})

      assert ClientIP.client_ip(conn) == "172.30.0.1"
    end

    test "falls back to the leftmost chain entry when every hop is a trusted proxy", %{
      conn: conn
    } do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["172.30.0.0/24"])

      conn =
        conn
        |> Map.put(:remote_ip, {172, 30, 0, 1})
        |> put_req_header("x-forwarded-for", "172.30.0.9, 172.30.0.12")

      assert ClientIP.client_ip(conn) == "172.30.0.9"
    end

    test "resolves clients whose own address falls inside a trusted CIDR", %{conn: conn} do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      # e.g. an admin reaching the app over the NetBird mesh: their address is
      # inside a trusted range, so no chain entry is "untrusted".
      Application.put_env(:elektrine, :trusted_proxy_cidrs, [
        "172.30.0.0/24",
        "100.100.0.0/16"
      ])

      conn =
        conn
        |> Map.put(:remote_ip, {172, 30, 0, 5})
        |> put_req_header("x-forwarded-for", "100.100.4.7")

      assert ClientIP.client_ip(conn) == "100.100.4.7"
    end

    test "records private VPN tunnel clients forwarded by a trusted proxy", %{conn: conn} do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["172.30.0.0/24"])

      conn =
        conn
        |> Map.put(:remote_ip, {172, 30, 0, 5})
        |> put_req_header("x-forwarded-for", "10.8.0.6")

      assert ClientIP.client_ip(conn) == "10.8.0.6"
    end

    test "uses x-real-ip when x-forwarded-for is absent", %{conn: conn} do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["172.30.0.0/24"])

      conn =
        conn
        |> Map.put(:remote_ip, {172, 30, 0, 5})
        |> put_req_header("x-real-ip", "203.0.113.61")

      assert ClientIP.client_ip(conn) == "203.0.113.61"
    end

    test "prefers the rightmost untrusted hop over a spoofable leftmost entry", %{conn: conn} do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["10.0.0.0/8"])

      # A client sent "x-forwarded-for: 8.8.8.8" and an appending proxy added
      # the real client address after it; only the rightmost entry is credible.
      conn =
        conn
        |> Map.put(:remote_ip, {10, 20, 30, 40})
        |> put_req_header("x-forwarded-for", "8.8.8.8, 203.0.113.9")

      assert ClientIP.client_ip(conn) == "203.0.113.9"
    end

    test "ignores forwarded headers from untrusted peers", %{conn: conn} do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["172.30.0.0/24"])

      conn =
        conn
        |> Map.put(:remote_ip, {203, 0, 113, 20})
        |> put_req_header("x-forwarded-for", "198.51.100.15")

      assert ClientIP.client_ip(conn) == "203.0.113.20"
    end
  end

  describe "forwarded_as_https?/1" do
    test "returns true only when a trusted proxy marks the request as https", %{conn: conn} do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["10.0.0.0/8"])

      trusted_conn =
        conn
        |> Map.put(:remote_ip, {10, 20, 30, 40})
        |> put_req_header("x-forwarded-proto", "https")

      untrusted_conn =
        conn
        |> Map.put(:remote_ip, {203, 0, 113, 20})
        |> put_req_header("x-forwarded-proto", "https")

      assert ClientIP.forwarded_as_https?(trusted_conn)
      refute ClientIP.forwarded_as_https?(untrusted_conn)
    end

    test "returns false when x-forwarded-proto is set by an untrusted peer", %{conn: conn} do
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      Application.put_env(:elektrine, :trusted_proxy_cidrs, [])

      conn =
        conn
        |> Map.put(:remote_ip, {203, 0, 113, 20})
        |> put_req_header("x-forwarded-proto", "https")

      refute ClientIP.forwarded_as_https?(conn)
    end
  end
end
