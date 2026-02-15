defmodule ElektrineWeb.VPNAPIController do
  @moduledoc """
  API endpoints for VPN servers to interact with the platform.
  These endpoints are called by the WireGuard server management scripts.

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
  use ElektrineWeb, :controller

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

    # Try cache first
    case Elektrine.VPN.PeerCache.get(server_id) do
      nil ->
        # Cache miss - fetch from DB
        server = VPN.get_server!(server_id)

        # Get active configs for users who are not banned/suspended
        active_configs =
          from(uc in Elektrine.VPN.UserConfig,
            join: u in Elektrine.Accounts.User,
            on: u.id == uc.user_id,
            where:
              uc.vpn_server_id == ^server_id and
                uc.status == "active" and
                u.banned == false and
                u.suspended == false,
            select: %{
              public_key: uc.public_key,
              allocated_ip: uc.allocated_ip,
              allowed_ips: uc.allowed_ips,
              persistent_keepalive: uc.persistent_keepalive,
              rate_limit_mbps: uc.rate_limit_mbps
            }
          )
          |> Elektrine.Repo.all()

        # Get configs that should be removed (suspended, revoked, or banned users)
        peers_to_remove =
          from(uc in Elektrine.VPN.UserConfig,
            left_join: u in Elektrine.Accounts.User,
            on: u.id == uc.user_id,
            where:
              uc.vpn_server_id == ^server_id and
                (uc.status in ["suspended", "revoked"] or
                   u.banned == true or
                   u.suspended == true),
            select: %{
              public_key: uc.public_key
            }
          )
          |> Elektrine.Repo.all()

        response = %{
          server: %{
            id: server.id,
            name: server.name,
            internal_ip_range: server.internal_ip_range,
            dns_servers: server.dns_servers
          },
          peers: active_configs,
          remove_peers: peers_to_remove
        }

        # Cache it
        Elektrine.VPN.PeerCache.put(server_id, response)

        json(conn, response)

      cached_response ->
        # Cache hit
        json(conn, cached_response)
    end
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

    # Batch update: find all configs in one query
    public_keys = Enum.map(peers, & &1["public_key"])

    user_configs =
      from(uc in Elektrine.VPN.UserConfig,
        join: u in Elektrine.Accounts.User,
        on: u.id == uc.user_id,
        where:
          uc.vpn_server_id == ^server_id and
            uc.public_key in ^public_keys,
        preload: [user: []]
      )
      |> Elektrine.Repo.all()
      |> Enum.map(&{&1.public_key, &1})
      |> Map.new()

    # Update stats in memory (fast!)
    Enum.each(peers, fn peer ->
      if user_config = Map.get(user_configs, peer["public_key"]) do
        bytes_sent = peer["bytes_sent"] || 0
        bytes_received = peer["bytes_received"] || 0

        # Record in StatsAggregator (in-memory, very fast)
        Elektrine.VPN.StatsAggregator.record_bandwidth(
          server_id,
          user_config.id,
          bytes_sent,
          bytes_received
        )

        # Check and update quota in background
        Task.start(fn ->
          try do
            check_and_update_quota(
              user_config,
              bytes_sent,
              bytes_received,
              peer["last_handshake"]
            )
          rescue
            e ->
              Logger.error(
                "Failed to update quota for user_config #{user_config.id}: #{inspect(e)}"
              )
          end
        end)
      else
        Logger.warning("No user_config found for peer: #{peer["public_key"]}")
      end
    end)

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

    # Record heartbeat in HealthMonitor (in-memory, fast)
    Elektrine.VPN.HealthMonitor.heartbeat(server_id)

    # Update DB asynchronously (non-blocking)
    spawn(fn ->
      server = VPN.get_server!(server_id)

      VPN.update_server(server, %{
        current_users: current_users,
        status: status
      })
    end)

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
  - country_code, city, endpoint_port, internal_ip_range, dns_servers

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
            public_key: params["public_key"],
            country_code: params["country_code"],
            city: params["city"],
            endpoint_port: params["endpoint_port"],
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
        # Server already exists - return existing credentials
        Logger.info(
          "Server already registered: #{existing_server.name} (ID: #{existing_server.id})"
        )

        # Optionally update public_key if it changed
        if params["public_key"] && params["public_key"] != existing_server.public_key do
          Logger.info("Updating public key for server #{existing_server.id}")
          VPN.update_server(existing_server, %{public_key: params["public_key"]})
        end

        json(conn, %{
          status: "already_registered",
          server_id: existing_server.id,
          api_key: existing_server.api_key,
          message: "Server already registered, returning existing credentials"
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

  # Private functions

  defp send_quota_notifications(user_config, quota_percent) do
    # Load user with email
    user = Elektrine.Repo.get!(Elektrine.Accounts.User, user_config.user_id)

    # Store last notification in metadata to avoid spam
    last_notification = get_in(user_config.metadata, ["last_quota_notification"]) || 0

    cond do
      # 100%+ (suspended) - send once
      quota_percent >= 100 && last_notification < 100 ->
        Elektrine.Email.Sender.send_vpn_quota_suspended(user, user_config)
        update_notification_metadata(user_config, 100)

      # 90% warning - send once
      quota_percent >= 90 && last_notification < 90 ->
        Elektrine.Email.Sender.send_vpn_quota_warning(user, user_config, 90)
        update_notification_metadata(user_config, 90)

      # 80% warning - send once
      quota_percent >= 80 && last_notification < 80 ->
        Elektrine.Email.Sender.send_vpn_quota_warning(user, user_config, 80)
        update_notification_metadata(user_config, 80)

      true ->
        :ok
    end
  end

  defp update_notification_metadata(user_config, threshold) do
    new_metadata = Map.put(user_config.metadata || %{}, "last_quota_notification", threshold)

    from(uc in Elektrine.VPN.UserConfig, where: uc.id == ^user_config.id)
    |> Elektrine.Repo.update_all(set: [metadata: new_metadata])
  end

  defp check_and_update_quota(user_config, bytes_sent, bytes_received, last_handshake) do
    now = DateTime.utc_now()

    # Check if user is banned or suspended (site-wide)
    user = Elektrine.Repo.get!(Elektrine.Accounts.User, user_config.user_id)

    # If user is banned or suspended, revoke their VPN access immediately
    if user.banned || user.suspended do
      # Revoke the config and invalidate cache
      from(uc in Elektrine.VPN.UserConfig, where: uc.id == ^user_config.id)
      |> Elektrine.Repo.update_all(set: [status: "revoked"])

      Elektrine.VPN.PeerCache.invalidate(user_config.vpn_server_id)

      {:ok, :revoked_banned_user}
    else
      # Initialize quota period if not set
      quota_period_start = user_config.quota_period_start || now

      # Check if we need to reset the quota (monthly)
      quota_period_start =
        if DateTime.diff(now, quota_period_start, :day) >= 30 do
          # Reset quota for new month
          now
        else
          quota_period_start
        end

      # Calculate bandwidth delta (handles VPN server restarts)
      previous_total = user_config.bytes_sent + user_config.bytes_received
      current_total = bytes_sent + bytes_received

      # If current < previous, server restarted (counters reset to 0)
      # In this case, add current_total as new usage
      # Otherwise, add the delta
      bandwidth_delta =
        if current_total < previous_total do
          # Server restarted, track new session
          current_total
        else
          # Normal case: accumulate delta
          current_total - previous_total
        end

      # Calculate quota used (reset if period changed, otherwise accumulate)
      quota_used_bytes =
        if quota_period_start == user_config.quota_period_start do
          # Same period: add delta to existing quota usage
          user_config.quota_used_bytes + bandwidth_delta
        else
          # New period: reset quota and start fresh
          current_total
        end

      # Check if over quota and suspend if necessary (105% grace period)
      quota_percent =
        if user_config.bandwidth_quota_bytes > 0,
          do: quota_used_bytes / user_config.bandwidth_quota_bytes * 100,
          else: 0

      # Send email notifications at thresholds
      spawn(fn ->
        send_quota_notifications(user_config, quota_percent)
      end)

      # Suspend at 105% to give users a grace period
      new_status =
        if quota_percent > 105 && user_config.status == "active" do
          "suspended"
        else
          user_config.status
        end

      # Update database
      updates = [
        bytes_sent: bytes_sent,
        bytes_received: bytes_received,
        quota_period_start: quota_period_start,
        quota_used_bytes: quota_used_bytes,
        status: new_status
      ]

      updates =
        if last_handshake do
          case DateTime.from_iso8601(last_handshake) do
            {:ok, datetime, _} -> Keyword.put(updates, :last_handshake_at, datetime)
            _ -> updates
          end
        else
          updates
        end

      result =
        from(uc in Elektrine.VPN.UserConfig, where: uc.id == ^user_config.id)
        |> Elektrine.Repo.update_all(set: updates)

      # Invalidate cache if status changed
      if new_status != user_config.status do
        Elektrine.VPN.PeerCache.invalidate(user_config.vpn_server_id)
      end

      result
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
