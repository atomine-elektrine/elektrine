defmodule ElektrineWeb.Routes.VPN do
  @moduledoc false

  defmacro admin_routes do
    quote do
      scope "/", alias: false do
        get("/vpn", ElektrineVPNWeb.Admin.VPNController, :dashboard)
        get("/vpn/servers/new", ElektrineVPNWeb.Admin.VPNController, :new_server)
        post("/vpn/servers", ElektrineVPNWeb.Admin.VPNController, :create_server)
        get("/vpn/servers/:id/edit", ElektrineVPNWeb.Admin.VPNController, :edit_server)

        get(
          "/vpn/servers/:id/confirm-delete",
          ElektrineVPNWeb.Admin.VPNController,
          :confirm_delete_server
        )

        put("/vpn/servers/:id", ElektrineVPNWeb.Admin.VPNController, :update_server)
        delete("/vpn/servers/:id", ElektrineVPNWeb.Admin.VPNController, :delete_server)
        get("/vpn/users", ElektrineVPNWeb.Admin.VPNController, :users)
        get("/vpn/users/:id/edit", ElektrineVPNWeb.Admin.VPNController, :edit_user_config)
        put("/vpn/users/:id", ElektrineVPNWeb.Admin.VPNController, :update_user_config)
        post("/vpn/users/:id/reset-quota", ElektrineVPNWeb.Admin.VPNController, :reset_user_quota)
      end
    end
  end

  defmacro internal_api_routes do
    quote do
      post("/vpn/register", ElektrineVPNWeb.VPNAPIController, :auto_register)
      get("/vpn/:server_id/peers", ElektrineVPNWeb.VPNAPIController, :get_peers)
      post("/vpn/:server_id/stats", ElektrineVPNWeb.VPNAPIController, :update_stats)
      post("/vpn/:server_id/heartbeat", ElektrineVPNWeb.VPNAPIController, :heartbeat)
      post("/vpn/:server_id/connection", ElektrineVPNWeb.VPNAPIController, :log_connection)
      post("/vpn/:server_id/register-key", ElektrineVPNWeb.VPNAPIController, :register_key)
      post("/vpn/:server_id/check-peer", ElektrineVPNWeb.VPNAPIController, :check_peer)
    end
  end

  defmacro authenticated_api_routes do
    quote do
      get("/vpn/servers", ElektrineVPNWeb.API.VPNController, :index)
      get("/vpn/configs", ElektrineVPNWeb.API.VPNController, :list_configs)
      get("/vpn/configs/:id", ElektrineVPNWeb.API.VPNController, :show_config)
      post("/vpn/configs", ElektrineVPNWeb.API.VPNController, :create_config)
      delete("/vpn/configs/:id", ElektrineVPNWeb.API.VPNController, :delete_config)
    end
  end

  defmacro public_live_routes do
    quote do
      scope "/", alias: false do
        live("/vpn/policy", ElektrineVPNWeb.PageLive.VPNPolicy, :index)
      end
    end
  end

  defmacro main_live_routes do
    quote do
      scope "/", alias: false do
        live("/vpn", ElektrineVPNWeb.VPNLive.Index, :index)
      end
    end
  end

  def path_prefixes do
    ["/vpn", "/api/vpn", "/pripyat/vpn"]
  end

  def view_modules do
    [ElektrineVPNWeb.PageLive.VPNPolicy, ElektrineVPNWeb.VPNLive.Index]
  end
end
