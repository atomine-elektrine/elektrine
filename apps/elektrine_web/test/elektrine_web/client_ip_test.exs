defmodule ElektrineWeb.ClientIPTest do
  use ElektrineWeb.ConnCase, async: false

  alias ElektrineWeb.ClientIP

  describe "client_ip/1" do
    test "uses fly-client-ip when running on fly even if trusted proxies are unset", %{conn: conn} do
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
        |> put_req_header("fly-client-ip", "198.51.100.42")

      assert ClientIP.client_ip(conn) == "198.51.100.42"
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

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
