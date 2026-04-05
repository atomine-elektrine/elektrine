defmodule ElektrineVPNWeb.VPNAPIController do
  @moduledoc """
  API endpoints for VPN servers and self-hosted WireGuard integrations.
  These endpoints are used by external/fleet-managed nodes; the one-box default path
  now reconciles directly in-app.

  ## Active Enforcement of Banned/Suspended Users

  To ensure banned/suspended users cannot use VPN even with downloaded configs:

  1. **Periodic Sync (Recommended every 60 seconds)**:
     - Call `GET /vpn/:server_id/peers`
     - Response includes `peers` (allowed) and `remove_peers` (to remove)
     - Use `wg set wg0 peer <public_key> remove` for each peer in `remove_peers`
     - Then sync all allowed peers from `peers` array

  2. **Real-time Check (Optional, on connection attempt)**:
     - Call `POST /vpn/:server_id/check-peer` with `public_key`
     - Returns `{allowed: false, reason: "user_banned"}` if should be blocked
     - Use WireGuard's authentication hooks to deny connection

  3. **Stats Updates (Already implemented)**:
     - When calling `POST /vpn/:server_id/stats`, banned users are auto-revoked
     - Cache is invalidated, forcing next sync to exclude them

  Banned users will be disconnected within 60 seconds of ban (or immediately on next sync).
  """
  use ElektrineVPNWeb, :controller

  import Ecto.Query
  alias Elektrine.VPN

  # Auto-registration endpoint doesn't need per-server API key
  plug :verify_fleet_key when action in [:auto_register]
  plug :verify_api_key when action not in [:auto_register]

  @doc """
  Get peer configurations for a specific VPN server.
  Returns all active user configs for the server and peers to remove.
  Uses cache to reduce DB load.
  """
  def get_peers(conn, %{"server_id" => server_id}) do
    server_id = String.to_integer(server_id)

    json(conn, VPN.peer_sync_snapshot(server_id))
  end

  @doc """
  Update connection statistics for users.
  Called periodically by the VPN server to report handshakes and bandwidth.
  Uses StatsAggregator for fast in-memory updates.
  """
  def update_stats(conn, %{"server_id" => server_id, "peers" => peers}) do
    require Logger
    server_id = String.to_integer(server_id)

    Logger.debug("VPN Stats received for server #{server_id}: #{length(peers)} peers")

    :ok = VPN.report_peer_stats(server_id, peers)

    json(conn, %{status: "ok", updated: length(peers)})
  end

  @doc """
  Report server health and status.
  Records heartbeat in HealthMonitor for fast health checks.
  """
  def heartbeat(conn, %{
        "server_id" => server_id,
        "current_users" => current_users,
        "status" => status
      }) do
    server_id = String.to_integer(server_id)

    :ok = VPN.report_server_heartbeat(server_id, current_users, status)

    json(conn, %{status: "ok"})
  end

  @doc """
  Register or update the server's public key.
  Useful for RAM-only servers where keys may be ephemeral or regenerated.
  """
  def register_key(conn, %{"server_id" => server_id, "public_key" => public_key}) do
    server_id = String.to_integer(server_id)
    server = VPN.get_server!(server_id)

    case VPN.update_server(server, %{public_key: public_key}) do
      {:ok, _updated_server} ->
        json(conn, %{status: "ok", message: "Public key registered successfully"})

      {:error, changeset} ->
        conn
        |> put_status(400)
        |> json(%{error: "Failed to register public key", details: changeset})
    end
  end

  @doc """
  Check if a peer is allowed to connect.
  Returns whether the peer should be allowed based on user status.
  """
  def check_peer(conn, %{"server_id" => server_id, "public_key" => public_key}) do
    server_id = String.to_integer(server_id)

    # Find the user config
    user_config =
      from(uc in Elektrine.VPN.UserConfig,
        join: u in Elektrine.Accounts.User,
        on: u.id == uc.user_id,
        where: uc.vpn_server_id == ^server_id and uc.public_key == ^public_key,
        preload: [user: []]
      )
      |> Elektrine.Repo.one()

    case user_config do
      nil ->
        # Config not found
        json(conn, %{allowed: false, reason: "config_not_found"})

      config ->
        user = config.user

        cond do
          # User is banned
          user.banned ->
            json(conn, %{allowed: false, reason: "user_banned"})

          # User is suspended
          user.suspended ->
            json(conn, %{allowed: false, reason: "user_suspended"})

          # Config is revoked
          config.status == "revoked" ->
            json(conn, %{allowed: false, reason: "config_revoked"})

          # Config is suspended (quota exceeded)
          config.status == "suspended" ->
            json(conn, %{allowed: false, reason: "quota_exceeded"})

          # Config is active
          config.status == "active" ->
            json(conn, %{allowed: true})

          # Unknown status
          true ->
            json(conn, %{allowed: false, reason: "invalid_status"})
        end
    end
  end

  @doc """
  Auto-register a new VPN server in the fleet.
  This endpoint allows VPN servers to self-register when they start up.

  Required params:
  - name: Server name (e.g., hostname)
  - location: Geographic location description
  - public_ip: Public IP address of the server
  - public_key: WireGuard public key

  Optional params:
  - country_code, city, endpoint_host, endpoint_port, client_mtu, internal_ip_range, dns_servers

  Returns server_id and api_key for future authentication.
  """
  def auto_register(conn, params) do
    require Logger

    public_ip = params["public_ip"]

    # Check if server already exists
    case VPN.get_server_by_ip(public_ip) do
      nil ->
        # New server - create it
        Logger.info("Auto-registering new VPN server: #{params["name"]} (#{public_ip})")

        attrs =
          %{
            name: params["name"],
            location: params["location"],
            public_ip: public_ip,
            endpoint_host: params["endpoint_host"],
            public_key: params["public_key"],
            country_code: params["country_code"],
            city: params["city"],
            endpoint_port: params["endpoint_port"],
            client_mtu: params["client_mtu"],
            internal_ip_range: params["internal_ip_range"],
            dns_servers: params["dns_servers"]
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        case VPN.auto_register_server(attrs) do
          {:ok, server} ->
            Logger.info("Successfully auto-registered server ID #{server.id}")

            json(conn, %{
              status: "registered",
              server_id: server.id,
              api_key: server.api_key,
              message: "Server successfully registered"
            })

          {:error, changeset} ->
            Logger.error("Failed to auto-register server: #{inspect(changeset.errors)}")

            conn
            |> put_status(400)
            |> json(%{
              error: "Failed to register server",
              details: translate_errors(changeset)
            })
        end

      existing_server ->
        # Server already exists - do not disclose credentials through fleet bootstrap.
        Logger.info(
          "Server already registered: #{existing_server.name} (ID: #{existing_server.id})"
        )

        conn
        |> put_status(:conflict)
        |> json(%{
          error: "Server already registered",
          server_id: existing_server.id,
          message: "Existing VPN server credentials cannot be recovered via fleet bootstrap"
        })
    end
  end

  @doc """
  Log a connection event (connect/disconnect).
  """
  def log_connection(conn, params) do
    %{
      "server_id" => server_id,
      "public_key" => public_key,
      "event" => event
    } = params

    server_id = String.to_integer(server_id)

    # Find user config
    user_config =
      from(uc in Elektrine.VPN.UserConfig,
        where: uc.vpn_server_id == ^server_id and uc.public_key == ^public_key
      )
      |> Elektrine.Repo.one()

    if user_config do
      case event do
        "connect" ->
          VPN.create_connection_log(%{
            vpn_user_config_id: user_config.id,
            connected_at: DateTime.utc_now(),
            client_ip: params["client_ip"]
          })

        "disconnect" ->
          # Find the most recent open connection and close it
          log =
            from(cl in Elektrine.VPN.ConnectionLog,
              where: cl.vpn_user_config_id == ^user_config.id and is_nil(cl.disconnected_at),
              order_by: [desc: cl.connected_at],
              limit: 1
            )
            |> Elektrine.Repo.one()

          if log do
            VPN.update_connection_log(log, %{
              disconnected_at: DateTime.utc_now(),
              bytes_sent: params["bytes_sent"] || 0,
              bytes_received: params["bytes_received"] || 0
            })
          end

        _ ->
          nil
      end

      json(conn, %{status: "ok"})
    else
      conn
      |> put_status(404)
      |> json(%{error: "User config not found"})
    end
  end

  defp verify_api_key(conn, _opts) do
    # Get API key from Authorization header
    api_key = get_req_header(conn, "authorization") |> List.first()

    # Extract server_id from params
    server_id = conn.params["server_id"]

    if server_id && api_key do
      server_id = String.to_integer(server_id)

      case Elektrine.Repo.get(VPN.Server, server_id) do
        nil ->
          conn
          |> put_status(404)
          |> json(%{error: "VPN server not found"})
          |> halt()

        server ->
          # Check if API key matches (use constant-time comparison to prevent timing attacks)
          expected_key = "Bearer #{server.api_key}"

          if Plug.Crypto.secure_compare(api_key, expected_key) do
            conn
          else
            conn
            |> put_status(401)
            |> json(%{error: "Invalid API key"})
            |> halt()
          end
      end
    else
      conn
      |> put_status(401)
      |> json(%{error: "Missing credentials"})
      |> halt()
    end
  end

  defp verify_fleet_key(conn, _opts) do
    # Get fleet registration key from Authorization header
    auth_header = get_req_header(conn, "authorization") |> List.first()

    # Get fleet key from environment
    fleet_key = System.get_env("VPN_FLEET_REGISTRATION_KEY")
    expected = "Bearer #{fleet_key}"

    # Use secure_compare to prevent timing attacks
    if fleet_key && auth_header && Plug.Crypto.secure_compare(auth_header, expected) do
      conn
    else
      conn
      |> put_status(401)
      |> json(%{error: "Invalid or missing fleet registration key"})
      |> halt()
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
