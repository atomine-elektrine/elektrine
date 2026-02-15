defmodule ElektrineWeb.Admin.VPNController do
  use ElektrineWeb, :controller

  import Ecto.Query

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}

  def dashboard(conn, _params) do
    servers = Elektrine.VPN.list_servers()

    # Get total stats
    total_configs = Elektrine.Repo.aggregate(Elektrine.VPN.UserConfig, :count, :id)

    total_active_configs =
      from(uc in Elektrine.VPN.UserConfig, where: uc.status == "active")
      |> Elektrine.Repo.aggregate(:count, :id)

    # Calculate bandwidth analytics
    all_configs = Elektrine.Repo.all(Elektrine.VPN.UserConfig)

    total_bandwidth =
      Enum.reduce(all_configs, 0, fn config, acc -> acc + config.quota_used_bytes end)

    total_quota =
      Enum.reduce(all_configs, 0, fn config, acc -> acc + config.bandwidth_quota_bytes end)

    quota_usage_percent =
      if total_quota > 0, do: (total_bandwidth / total_quota * 100) |> round(), else: 0

    # Get top bandwidth users
    top_users =
      from(uc in Elektrine.VPN.UserConfig,
        where: uc.quota_used_bytes > 0,
        order_by: [desc: uc.quota_used_bytes],
        limit: 10,
        preload: [:user, :vpn_server]
      )
      |> Elektrine.Repo.all()

    user = conn.assigns.current_user
    timezone = if user && user.timezone, do: user.timezone, else: "Etc/UTC"
    time_format = if user && user.time_format, do: user.time_format, else: "12"

    render(conn, :vpn_dashboard,
      servers: servers,
      total_configs: total_configs,
      total_active_configs: total_active_configs,
      total_bandwidth: total_bandwidth,
      quota_usage_percent: quota_usage_percent,
      top_users: top_users,
      timezone: timezone,
      time_format: time_format
    )
  end

  def new_server(conn, _params) do
    changeset = Elektrine.VPN.change_server(%Elektrine.VPN.Server{})
    render(conn, :new_vpn_server, changeset: changeset)
  end

  def create_server(conn, %{"server" => server_params}) do
    # Generate API key for the server
    api_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    server_params = Map.put(server_params, "api_key", api_key)

    case Elektrine.VPN.create_server(server_params) do
      {:ok, _server} ->
        conn
        |> put_flash(:info, "VPN server created successfully! API Key: #{api_key}")
        |> redirect(to: ~p"/pripyat/vpn")

      {:error, changeset} ->
        render(conn, :new_vpn_server, changeset: changeset)
    end
  end

  def edit_server(conn, %{"id" => id}) do
    server = Elektrine.VPN.get_server!(id)
    changeset = Elektrine.VPN.change_server(server)
    user = conn.assigns.current_user
    timezone = if user && user.timezone, do: user.timezone, else: "Etc/UTC"
    time_format = if user && user.time_format, do: user.time_format, else: "12"

    render(conn, :edit_vpn_server,
      server: server,
      changeset: changeset,
      timezone: timezone,
      time_format: time_format
    )
  end

  def update_server(conn, %{"id" => id, "server" => server_params}) do
    server = Elektrine.VPN.get_server!(id)

    case Elektrine.VPN.update_server(server, server_params) do
      {:ok, updated_server} ->
        # Invalidate cache when server config changes
        Elektrine.VPN.PeerCache.invalidate(updated_server.id)

        conn
        |> put_flash(:info, "VPN server updated successfully")
        |> redirect(to: ~p"/pripyat/vpn")

      {:error, changeset} ->
        user = conn.assigns.current_user
        timezone = if user && user.timezone, do: user.timezone, else: "Etc/UTC"
        time_format = if user && user.time_format, do: user.time_format, else: "12"

        render(conn, :edit_vpn_server,
          server: server,
          changeset: changeset,
          timezone: timezone,
          time_format: time_format
        )
    end
  end

  def confirm_delete_server(conn, %{"id" => id}) do
    server = Elektrine.VPN.get_server!(id)
    user_config_count = Elektrine.VPN.count_server_user_configs(id)

    render(conn, :confirm_delete_vpn_server,
      server: server,
      user_config_count: user_config_count
    )
  end

  def delete_server(conn, %{"id" => id, "confirmed" => "true"}) do
    server = Elektrine.VPN.get_server!(id)
    user_config_count = Elektrine.VPN.count_server_user_configs(id)

    case Elektrine.VPN.delete_server(server) do
      {:ok, _server} ->
        conn
        |> put_flash(
          :info,
          "VPN server and #{user_config_count} user configuration(s) deleted successfully"
        )
        |> redirect(to: ~p"/pripyat/vpn")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to delete server")
        |> redirect(to: ~p"/pripyat/vpn")
    end
  end

  def delete_server(conn, %{"id" => id}) do
    # Redirect to confirmation page if not confirmed
    redirect(conn, to: ~p"/pripyat/vpn/servers/#{id}/confirm-delete")
  end

  def users(conn, params) do
    page = Map.get(params, "page", "1") |> String.to_integer()
    per_page = 50

    # Get all VPN user configs with preloads
    query =
      from(uc in Elektrine.VPN.UserConfig,
        preload: [:user, :vpn_server],
        order_by: [desc: uc.inserted_at]
      )

    total_count = Elektrine.Repo.aggregate(query, :count, :id)
    total_pages = ceil(total_count / per_page)

    user_configs =
      query
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Elektrine.Repo.all()

    user = conn.assigns.current_user
    timezone = if user && user.timezone, do: user.timezone, else: "Etc/UTC"
    time_format = if user && user.time_format, do: user.time_format, else: "12"

    render(conn, :vpn_users,
      user_configs: user_configs,
      page: page,
      total_pages: total_pages,
      total_count: total_count,
      timezone: timezone,
      time_format: time_format
    )
  end

  def edit_user_config(conn, %{"id" => id}) do
    config =
      Elektrine.VPN.UserConfig
      |> Elektrine.Repo.get!(id)
      |> Elektrine.Repo.preload([:user, :vpn_server])

    changeset = Elektrine.VPN.UserConfig.changeset(config, %{})

    render(conn, :edit_vpn_user_config, config: config, changeset: changeset)
  end

  def update_user_config(conn, %{"id" => id, "config" => config_params}) do
    config =
      Elektrine.VPN.UserConfig
      |> Elektrine.Repo.get!(id)
      |> Elektrine.Repo.preload([:user, :vpn_server])

    # Convert GB to bytes for quota
    config_params =
      if quota_gb = config_params["bandwidth_quota_gb"] do
        quota_bytes = (String.to_float(quota_gb) * 1_073_741_824) |> round()
        Map.put(config_params, "bandwidth_quota_bytes", quota_bytes)
      else
        config_params
      end

    changeset = Elektrine.VPN.UserConfig.changeset(config, config_params)

    case Elektrine.Repo.update(changeset) do
      {:ok, _config} ->
        # Invalidate cache so changes take effect immediately
        Elektrine.VPN.PeerCache.invalidate(config.vpn_server_id)

        conn
        |> put_flash(:info, "VPN configuration updated successfully")
        |> redirect(to: ~p"/pripyat/vpn/users")

      {:error, changeset} ->
        render(conn, :edit_vpn_user_config, config: config, changeset: changeset)
    end
  end

  def reset_user_quota(conn, %{"id" => id}) do
    config = Elektrine.Repo.get!(Elektrine.VPN.UserConfig, id)

    changeset =
      Elektrine.VPN.UserConfig.changeset(config, %{
        quota_used_bytes: 0,
        quota_period_start: DateTime.utc_now(),
        status: "active"
      })

    case Elektrine.Repo.update(changeset) do
      {:ok, config} ->
        # Invalidate cache so user can reconnect immediately
        Elektrine.VPN.PeerCache.invalidate(config.vpn_server_id)

        conn
        |> put_flash(:info, "Quota reset successfully")
        |> redirect(to: ~p"/pripyat/vpn/users")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to reset quota")
        |> redirect(to: ~p"/pripyat/vpn/users")
    end
  end
end
