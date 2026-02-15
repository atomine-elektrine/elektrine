defmodule ElektrineWeb.API.VPNController do
  use ElektrineWeb, :controller

  alias Elektrine.VPN

  action_fallback ElektrineWeb.FallbackController

  @doc """
  GET /api/vpn/servers
  Lists all available VPN servers for the current user
  """
  def index(conn, _params) do
    user = conn.assigns[:current_user]

    # Get user's trust level
    user_trust_level = Map.get(user, :trust_level, 0)

    # Get servers user has access to
    servers = VPN.list_active_servers_for_user(user_trust_level)

    # Get user's configs to mark which servers they're already configured for
    user_configs = VPN.list_user_configs(user.id)
    configured_server_ids = Enum.map(user_configs, & &1.vpn_server_id)

    conn
    |> put_status(:ok)
    |> json(%{
      servers:
        Enum.map(servers, fn server ->
          %{
            id: server.id,
            name: server.name,
            location: server.location,
            country_code: server.country_code,
            public_ip: server.public_ip,
            endpoint_port: server.endpoint_port,
            status: server.status,
            current_users: server.current_users,
            max_users: server.max_users,
            minimum_trust_level: server.minimum_trust_level,
            is_configured: server.id in configured_server_ids
          }
        end)
    })
  end

  @doc """
  GET /api/vpn/configs
  Lists all VPN configurations for the current user
  """
  def list_configs(conn, _params) do
    user = conn.assigns[:current_user]

    configs = VPN.list_user_configs(user.id)

    conn
    |> put_status(:ok)
    |> json(%{
      configs: Enum.map(configs, &format_config/1)
    })
  end

  @doc """
  GET /api/vpn/configs/:id
  Gets a specific VPN configuration with WireGuard config file
  """
  def show_config(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case VPN.get_user_config!(id) do
      config when config.user_id == user.id ->
        # Generate WireGuard configuration file
        config_file = VPN.generate_config_file(config)

        conn
        |> put_status(:ok)
        |> json(%{
          config: format_config(config),
          wireguard_config: config_file
        })

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Access denied"})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Configuration not found"})
  end

  @doc """
  POST /api/vpn/configs
  Creates a new VPN configuration for a server
  Body: {"server_id": 1}
  """
  def create_config(conn, %{"server_id" => server_id}) do
    user = conn.assigns[:current_user]

    # Check if user already has a config for this server
    case VPN.get_user_config_by_user_and_server(user.id, server_id) do
      nil ->
        # Create new config
        case VPN.create_user_config(user.id, server_id) do
          {:ok, config} ->
            # Generate WireGuard configuration file
            config_file = VPN.generate_config_file(config)

            conn
            |> put_status(:created)
            |> json(%{
              message: "VPN configuration created successfully",
              config: format_config(config),
              wireguard_config: config_file
            })

          {:error, :server_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "VPN server not found"})

          {:error, :server_not_active} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "VPN server is not active"})

          {:error, %Ecto.Changeset{} = changeset} ->
            errors =
              Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
                Enum.reduce(opts, msg, fn {key, value}, acc ->
                  String.replace(acc, "%{#{key}}", to_string(value))
                end)
              end)

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to create configuration", errors: errors})
        end

      existing_config ->
        # User already has a config for this server
        config_file = VPN.generate_config_file(existing_config)

        conn
        |> put_status(:ok)
        |> json(%{
          message: "Configuration already exists",
          config: format_config(existing_config),
          wireguard_config: config_file
        })
    end
  end

  def create_config(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "server_id is required"})
  end

  @doc """
  DELETE /api/vpn/configs/:id
  Deletes a VPN configuration
  """
  def delete_config(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case VPN.get_user_config!(id) do
      config when config.user_id == user.id ->
        case VPN.delete_user_config(config) do
          {:ok, _} ->
            conn
            |> put_status(:ok)
            |> json(%{message: "VPN configuration deleted successfully"})

          {:error, _changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to delete configuration"})
        end

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Access denied"})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Configuration not found"})
  end

  # Private helper to format config for JSON response
  defp format_config(config) do
    %{
      id: config.id,
      server: %{
        id: config.vpn_server.id,
        name: config.vpn_server.name,
        location: config.vpn_server.location,
        country_code: config.vpn_server.country_code,
        public_ip: config.vpn_server.public_ip,
        endpoint_port: config.vpn_server.endpoint_port
      },
      allocated_ip: config.allocated_ip,
      status: config.status,
      bandwidth_quota_bytes: config.bandwidth_quota_bytes,
      quota_used_bytes: config.quota_used_bytes,
      bandwidth_remaining_bytes: config.bandwidth_quota_bytes - config.quota_used_bytes,
      rate_limit_mbps: config.rate_limit_mbps,
      last_handshake_at: config.last_handshake_at,
      bytes_sent: config.bytes_sent,
      bytes_received: config.bytes_received,
      inserted_at: config.inserted_at,
      updated_at: config.updated_at
    }
  end
end
