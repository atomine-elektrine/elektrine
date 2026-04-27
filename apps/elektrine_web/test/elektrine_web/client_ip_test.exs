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
