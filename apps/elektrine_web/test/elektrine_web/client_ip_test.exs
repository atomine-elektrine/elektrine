defmodule ElektrineWeb.ClientIPTest do
  use ElektrineWeb.ConnCase, async: false

  alias ElektrineWeb.ClientIP

  describe "client_ip/1" do
    test "prefers cf-connecting-ip over fly-client-ip when the remote peer is trusted", %{
      conn: conn
    } do
      previous_fly_app_name = System.get_env("FLY_APP_NAME")
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        restore_env("FLY_APP_NAME", previous_fly_app_name)
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      System.put_env("FLY_APP_NAME", "elektrine")
      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["10.0.0.0/8"])

      conn =
        conn
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> put_req_header("cf-connecting-ip", "203.0.113.77")
        |> put_req_header("fly-client-ip", "198.51.100.42")

      assert ClientIP.client_ip(conn) == "203.0.113.77"
    end

    test "ignores fly forwarding headers when the remote peer is not trusted", %{conn: conn} do
      previous_fly_app_name = System.get_env("FLY_APP_NAME")
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        restore_env("FLY_APP_NAME", previous_fly_app_name)
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      System.put_env("FLY_APP_NAME", "elektrine")
      Application.put_env(:elektrine, :trusted_proxy_cidrs, [])

      conn =
        conn
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> put_req_header("cf-connecting-ip", "203.0.113.77")
        |> put_req_header("fly-client-ip", "198.51.100.42")

      assert ClientIP.client_ip(conn) == "10.0.0.1"
    end

    test "ignores fly-client-ip header when not running on fly", %{conn: conn} do
      previous_fly_app_name = System.get_env("FLY_APP_NAME")

      on_exit(fn ->
        restore_env("FLY_APP_NAME", previous_fly_app_name)
      end)

      System.delete_env("FLY_APP_NAME")

      conn =
        conn
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> put_req_header("fly-client-ip", "198.51.100.42")

      assert ClientIP.client_ip(conn) == "10.0.0.1"
    end

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

    test "accepts Fly edge https forwarding even before trusted proxy cidrs are configured", %{
      conn: conn
    } do
      previous_fly_app_name = System.get_env("FLY_APP_NAME")
      previous_trusted_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs)

      on_exit(fn ->
        restore_env("FLY_APP_NAME", previous_fly_app_name)
        Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_cidrs)
      end)

      System.put_env("FLY_APP_NAME", "elektrine")
      Application.put_env(:elektrine, :trusted_proxy_cidrs, [])

      conn =
        conn
        |> Map.put(:remote_ip, {203, 0, 113, 20})
        |> put_req_header("x-forwarded-proto", "https")
        |> put_req_header("fly-client-ip", "198.51.100.42")

      assert ClientIP.forwarded_as_https?(conn)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
