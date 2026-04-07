defmodule Elektrine.VPN do
  @moduledoc """
  The VPN context - handles WireGuard VPN server and user configuration management.
  """

  import Ecto.Query, warn: false
  alias Elektrine.{PubSubTopics, Repo}
  alias Elektrine.VPN.{ConnectionLog, SelfHostedReconciler, Server, UserConfig}

  require Logger

  @self_host_metadata_key "managed_by"
  @self_host_metadata_value "self_host_env"
  @hashed_api_key_prefix "sha256:"

  ## Server functions

  @doc """
  Returns the list of VPN servers.
  """
  def list_servers do
    Repo.all(Server)
  end

  def self_host_server?(%Server{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, @self_host_metadata_key) == @self_host_metadata_value
  end

  def self_host_server?(_server), do: false

  @doc """
  Returns the list of active VPN servers.
  """
  def list_active_servers do
    from(s in Server, where: s.status == "active")
    |> Repo.all()
  end

  @doc """
  Returns the list of active VPN servers that the user has access to based on their trust level.
  """
  def list_active_servers_for_user(user_trust_level) do
    from(s in Server,
      where: s.status == "active" and s.minimum_trust_level <= ^user_trust_level
    )
    |> Repo.all()
  end

  @doc """
  Gets a single server.
  """
  def get_server!(id), do: Repo.get!(Server, id)

  @doc """
  Creates a server.
  """
  def create_server(attrs \\ %{}) do
    %Server{}
    |> Server.changeset(normalize_server_attrs(attrs))
    |> Repo.insert()
  end

  def ensure_self_host_server(env \\ System.get_env()) do
    case self_host_server_attrs(env) do
      nil ->
        {:ok, get_self_host_server()}

      attrs ->
        case get_self_host_server() || get_server_by_ip(attrs.public_ip) do
          nil ->
            create_self_host_server(attrs)

          %Server{} = server ->
            update_self_host_server(server, attrs)
        end
    end
  end

  def peer_sync_snapshot(server_id) do
    case Elektrine.VPN.PeerCache.get(server_id) do
      nil ->
        server = get_server!(server_id)

        active_configs =
          from(uc in UserConfig,
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
          |> Repo.all()

        peers_to_remove =
          from(uc in UserConfig,
            left_join: u in Elektrine.Accounts.User,
            on: u.id == uc.user_id,
            where:
              uc.vpn_server_id == ^server_id and
                (uc.status in ["suspended", "revoked"] or
                   u.banned == true or
                   u.suspended == true),
            select: %{public_key: uc.public_key}
          )
          |> Repo.all()

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

        Elektrine.VPN.PeerCache.put(server_id, response)
        response

      cached_response ->
        cached_response
    end
  end

  def report_peer_stats(server_id, peers) when is_list(peers) do
    public_keys = Enum.map(peers, & &1["public_key"])

    user_configs =
      from(uc in UserConfig,
        join: u in Elektrine.Accounts.User,
        on: u.id == uc.user_id,
        where:
          uc.vpn_server_id == ^server_id and
            uc.public_key in ^public_keys,
        preload: [user: []]
      )
      |> Repo.all()
      |> Enum.map(&{&1.public_key, &1})
      |> Map.new()

    Enum.each(peers, fn peer ->
      if user_config = Map.get(user_configs, peer["public_key"]) do
        bytes_sent = peer["bytes_sent"] || 0
        bytes_received = peer["bytes_received"] || 0

        Elektrine.VPN.StatsAggregator.record_bandwidth(
          server_id,
          user_config.id,
          bytes_sent,
          bytes_received
        )

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

    :ok
  end

  def report_server_heartbeat(server_id, current_users, status) do
    Elektrine.VPN.HealthMonitor.heartbeat(server_id)

    spawn(fn ->
      server = get_server!(server_id)

      update_server(server, %{
        current_users: current_users,
        status: status
      })
    end)

    :ok
  end

  @doc """
  Auto-registers a new VPN server from fleet deployment.
  Generates API key automatically and uses sensible defaults.
  """
  def auto_register_server(attrs) do
    # Generate a unique API key
    api_key = :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)

    # Set defaults for auto-registered servers
    attrs =
      attrs
      |> Map.put_new(:api_key, api_key)
      |> Map.put_new(:status, "active")
      |> Map.put_new(:max_users, 1000)
      |> Map.put_new(:current_users, 0)
      |> Map.put_new(:minimum_trust_level, 0)
      |> Map.put_new(:endpoint_port, 51_820)
      |> Map.put_new(:client_mtu, 1280)
      |> Map.put_new(:dns_servers, "1.1.1.1, 1.0.0.1")
      |> Map.put_new(:internal_ip_range, "10.8.0.0/24")

    case create_server(attrs) do
      {:ok, server} ->
        Logger.info("Auto-registered new VPN server: #{server.name} (ID: #{server.id})")
        {:ok, %{server | api_key: api_key}}

      {:error, changeset} = error ->
        Logger.error("Failed to auto-register VPN server: #{inspect(changeset.errors)}")
        error
    end
  end

  @doc """
  Gets a server by public IP, or returns nil if not found.
  """
  def get_server_by_ip(public_ip) do
    from(s in Server, where: s.public_ip == ^public_ip)
    |> Repo.one()
  end

  def get_self_host_server do
    from(s in Server,
      where:
        fragment("?->>? = ?", s.metadata, ^@self_host_metadata_key, ^@self_host_metadata_value),
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Updates a server.
  """
  def update_server(%Server{} = server, attrs) do
    server
    |> Server.changeset(normalize_server_attrs(attrs))
    |> Repo.update()
  end

  @doc """
  Deletes a server and all associated user configurations.
  """
  def delete_server(%Server{} = server) do
    Repo.delete(server)
  end

  @doc """
  Counts the number of user configurations for a server.
  """
  def count_server_user_configs(server_id) do
    from(uc in UserConfig, where: uc.vpn_server_id == ^server_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking server changes.
  """
  def change_server(%Server{} = server, attrs \\ %{}) do
    Server.changeset(server, attrs)
  end

  ## User Config functions

  @doc """
  Returns the list of user configs for a specific user.
  """
  def list_user_configs(user_id) do
    from(uc in UserConfig,
      where: uc.user_id == ^user_id,
      preload: [:vpn_server]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single user config.
  """
  def get_user_config!(id) do
    Repo.get!(UserConfig, id)
    |> Repo.preload([:vpn_server, :user])
  end

  @doc """
  Gets a user config by user_id and server_id.
  """
  def get_user_config_by_user_and_server(user_id, server_id) do
    from(uc in UserConfig,
      where: uc.user_id == ^user_id and uc.vpn_server_id == ^server_id,
      preload: [:vpn_server]
    )
    |> Repo.one()
  end

  @doc """
  Creates a user config with automatically generated WireGuard keys and IP allocation.
  """
  def create_user_config(user_id, server_id) do
    with {:ok, _server} <- get_available_server(user_id, server_id),
         {:ok, keys} <- generate_wireguard_keypair(),
         {:ok, allocated_ip} <- allocate_ip_for_user(server_id) do
      # Encrypt private key before storing
      encrypted_private_key = encrypt_private_key(keys.private_key)

      attrs = %{
        user_id: user_id,
        vpn_server_id: server_id,
        public_key: keys.public_key,
        private_key: encrypted_private_key,
        allocated_ip: allocated_ip,
        status: "active"
      }

      result =
        %UserConfig{}
        |> UserConfig.changeset(attrs)
        |> Repo.insert()

      case result do
        {:ok, config} ->
          # Don't increment current_users - that's based on actual connections
          # Invalidate peer cache for this server
          Elektrine.VPN.PeerCache.invalidate(server_id)
          SelfHostedReconciler.reconcile_now()

          config = Repo.preload(config, [:vpn_server])
          broadcast_vpn_event(user_id, {:vpn_config_created, config})

          {:ok, config}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Updates a user config.
  """
  def update_user_config(%UserConfig{} = user_config, attrs) do
    result =
      user_config
      |> UserConfig.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated_config} ->
        # Invalidate cache if status changed
        if Map.has_key?(attrs, :status) do
          Elektrine.VPN.PeerCache.invalidate(user_config.vpn_server_id)
          SelfHostedReconciler.reconcile_now()
        end

        updated_config = Repo.preload(updated_config, [:vpn_server])
        broadcast_vpn_event(updated_config.user_id, {:vpn_config_updated, updated_config})

        {:ok, updated_config}

      error ->
        error
    end
  end

  @doc """
  Deletes a user config.
  """
  def delete_user_config(%UserConfig{} = user_config) do
    server_id = user_config.vpn_server_id
    result = Repo.delete(user_config)

    case result do
      {:ok, deleted_config} ->
        # Don't decrement current_users - that's based on actual connections
        # Invalidate peer cache for this server
        Elektrine.VPN.PeerCache.invalidate(server_id)
        SelfHostedReconciler.reconcile_now()

        broadcast_vpn_event(deleted_config.user_id, {:vpn_config_deleted, deleted_config.id})

        {:ok, deleted_config}

      error ->
        error
    end
  end

  @doc """
  Generates a WireGuard configuration file for a user config.
  """
  def generate_config_file(%UserConfig{} = config) do
    config = Repo.preload(config, :vpn_server)
    server = config.vpn_server

    # Decrypt private key
    private_key = decrypt_private_key(config.private_key)
    endpoint_host = server_endpoint_host(server)
    mtu_line = config_mtu_line(server)

    """
    [Interface]
    PrivateKey = #{private_key}
    Address = #{config.allocated_ip}
    DNS = #{server.dns_servers}
    #{mtu_line}

    [Peer]
    PublicKey = #{server.public_key}
    Endpoint = #{endpoint_host}:#{server.endpoint_port}
    AllowedIPs = #{config.allowed_ips}
    PersistentKeepalive = #{config.persistent_keepalive}
    """
  end

  def valid_server_api_key?(%Server{api_key: stored_key}, api_key)
      when is_binary(stored_key) and is_binary(api_key) do
    if String.starts_with?(stored_key, @hashed_api_key_prefix) do
      secure_compare(stored_key, hash_api_key(api_key))
    else
      secure_compare(stored_key, api_key)
    end
  end

  def valid_server_api_key?(_server, _api_key), do: false

  ## Helper functions

  defp get_available_server(user_id, server_id) do
    server = Repo.get(Server, server_id)
    user_trust_level = get_user_trust_level(user_id)

    cond do
      is_nil(server) ->
        {:error, :server_not_found}

      server.status != "active" ->
        {:error, :server_not_active}

      server.minimum_trust_level > user_trust_level ->
        {:error, :insufficient_trust_level}

      true ->
        {:ok, server}
    end
  end

  defp create_self_host_server(attrs) do
    attrs
    |> Map.put(:api_key, generate_api_key())
    |> Map.put(:status, "active")
    |> Map.put(:max_users, 100)
    |> Map.put(:current_users, 0)
    |> Map.put(:minimum_trust_level, 0)
    |> create_server()
  end

  defp update_self_host_server(server, attrs) do
    merged_metadata =
      server.metadata
      |> ensure_map()
      |> Map.merge(Map.get(attrs, :metadata, %{}))

    updates =
      attrs
      |> Map.take([
        :name,
        :location,
        :country_code,
        :city,
        :public_ip,
        :endpoint_host,
        :public_key,
        :endpoint_port,
        :client_mtu,
        :internal_ip_range,
        :dns_servers
      ])
      |> Map.put(:metadata, merged_metadata)

    update_server(server, updates)
  end

  defp self_host_server_attrs(env) do
    public_ip = env_value(env, "VPN_SELFHOST_PUBLIC_IP")
    public_key = env_value(env, "VPN_SELFHOST_PUBLIC_KEY")

    if present?(public_ip) and present?(public_key) do
      %{
        name:
          env_value(env, "VPN_SELFHOST_NAME") || env_value(env, "PRIMARY_DOMAIN") || "WireGuard",
        location: env_value(env, "VPN_SELFHOST_LOCATION") || "Self-hosted",
        country_code: env_value(env, "VPN_SELFHOST_COUNTRY_CODE"),
        city: env_value(env, "VPN_SELFHOST_CITY"),
        public_ip: public_ip,
        endpoint_host: env_value(env, "VPN_SELFHOST_ENDPOINT_HOST"),
        public_key: public_key,
        endpoint_port:
          env_value(env, "VPN_SELFHOST_ENDPOINT_PORT") ||
            env_value(env, "VPN_SELFHOST_LISTEN_PORT") || 51_820,
        client_mtu: env_value(env, "VPN_SELFHOST_CLIENT_MTU") || 1280,
        internal_ip_range: env_value(env, "VPN_SELFHOST_INTERNAL_IP_RANGE") || "10.8.0.0/24",
        dns_servers: env_value(env, "VPN_SELFHOST_DNS_SERVERS") || "1.1.1.1, 1.0.0.1",
        metadata: %{@self_host_metadata_key => @self_host_metadata_value}
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp generate_api_key do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end

  defp normalize_server_attrs(attrs) when is_map(attrs) do
    case Map.get(attrs, :api_key) || Map.get(attrs, "api_key") do
      value when is_binary(value) and value != "" ->
        put_api_key(attrs, normalize_api_key(value))

      _ ->
        attrs
    end
  end

  defp normalize_server_attrs(attrs), do: attrs

  defp put_api_key(attrs, value) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, "api_key") -> Map.put(attrs, "api_key", value)
      Map.has_key?(attrs, :api_key) -> Map.put(attrs, :api_key, value)
      true -> Map.put(attrs, :api_key, value)
    end
  end

  defp normalize_api_key(api_key) do
    if String.starts_with?(api_key, @hashed_api_key_prefix) do
      api_key
    else
      hash_api_key(api_key)
    end
  end

  defp hash_api_key(api_key) do
    @hashed_api_key_prefix <> Base.encode16(:crypto.hash(:sha256, api_key), case: :lower)
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp get_user_trust_level(user_id) when is_integer(user_id) do
    case Repo.get(Elektrine.Accounts.User, user_id) do
      %{trust_level: trust_level} when is_integer(trust_level) -> trust_level
      _ -> 0
    end
  end

  defp get_user_trust_level(_user_id), do: 0

  defp env_value(env, key) when is_map(env) do
    case Map.get(env, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp present?(value) when is_binary(value), do: Elektrine.Strings.present?(value)
  defp present?(_value), do: false

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}

  defp generate_wireguard_keypair do
    # Generate proper WireGuard keypair using Curve25519 (X25519)
    # WireGuard uses Curve25519 for Diffie-Hellman key exchange

    # Generate the keypair using X25519
    {public_key_bytes, private_key_bytes} = :crypto.generate_key(:ecdh, :x25519)

    # Encode to Base64 (WireGuard format)
    private_key = Base.encode64(private_key_bytes)
    public_key = Base.encode64(public_key_bytes)

    {:ok, %{private_key: private_key, public_key: public_key}}
  end

  defp allocate_ip_for_user(server_id) do
    server = Repo.get!(Server, server_id)

    # Parse the internal IP range (e.g., "10.8.0.0/24")
    [base_ip, _cidr] = String.split(server.internal_ip_range, "/")
    [a, b, c, _d] = String.split(base_ip, ".") |> Enum.map(&String.to_integer/1)

    # Get all allocated IPs for this server
    allocated_ips =
      from(uc in UserConfig,
        where: uc.vpn_server_id == ^server_id,
        select: uc.allocated_ip
      )
      |> Repo.all()
      |> Enum.map(fn ip ->
        [_a, _b, _c, d] = String.split(ip, "/") |> List.first() |> String.split(".")
        String.to_integer(d)
      end)
      |> MapSet.new()

    # Find first available IP (start from .2, .1 is usually the gateway)
    available_ip =
      Enum.find(2..254, fn d ->
        !MapSet.member?(allocated_ips, d)
      end)

    case available_ip do
      nil -> {:error, :no_available_ips}
      d -> {:ok, "#{a}.#{b}.#{c}.#{d}/32"}
    end
  end

  defp encrypt_private_key(private_key) do
    # Use application secret to encrypt the private key
    # In production, use a proper encryption library
    secret =
      Application.get_env(:elektrine, ElektrineWeb.Endpoint)[:secret_key_base]
      |> binary_part(0, 32)

    iv = :crypto.strong_rand_bytes(16)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, private_key, "", true)

    iv <> tag <> ciphertext
  end

  defp decrypt_private_key(encrypted_data) when is_binary(encrypted_data) do
    secret =
      Application.get_env(:elektrine, ElektrineWeb.Endpoint)[:secret_key_base]
      |> binary_part(0, 32)

    <<iv::binary-16, tag::binary-16, ciphertext::binary>> = encrypted_data

    :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, ciphertext, "", tag, false)
  end

  defp decrypt_private_key(nil), do: nil

  defp server_endpoint_host(%Server{endpoint_host: endpoint_host, public_ip: public_ip}) do
    case normalize_optional_string(endpoint_host) do
      nil -> public_ip
      value -> value
    end
  end

  defp config_mtu_line(%Server{client_mtu: nil}), do: ""
  defp config_mtu_line(%Server{client_mtu: client_mtu}), do: "MTU = #{client_mtu}"

  defp normalize_optional_string(value) when is_binary(value),
    do: Elektrine.Strings.present(value)

  defp normalize_optional_string(_), do: nil

  defp broadcast_vpn_event(user_id, event) when is_integer(user_id) and user_id > 0 do
    Phoenix.PubSub.broadcast(Elektrine.PubSub, PubSubTopics.user_vpn(user_id), event)
  end

  defp broadcast_vpn_event(_, _), do: :ok

  defp check_and_update_quota(user_config, bytes_sent, bytes_received, last_handshake) do
    now = DateTime.utc_now()
    user = Repo.get!(Elektrine.Accounts.User, user_config.user_id)

    if user.banned || user.suspended do
      from(uc in UserConfig, where: uc.id == ^user_config.id)
      |> Repo.update_all(set: [status: "revoked"])

      Elektrine.VPN.PeerCache.invalidate(user_config.vpn_server_id)

      {:ok, :revoked_banned_user}
    else
      quota_period_start = user_config.quota_period_start || now

      quota_period_start =
        if DateTime.diff(now, quota_period_start, :day) >= 30 do
          now
        else
          quota_period_start
        end

      previous_total = user_config.bytes_sent + user_config.bytes_received
      current_total = bytes_sent + bytes_received

      bandwidth_delta =
        if current_total < previous_total do
          current_total
        else
          current_total - previous_total
        end

      quota_used_bytes =
        if quota_period_start == user_config.quota_period_start do
          user_config.quota_used_bytes + bandwidth_delta
        else
          current_total
        end

      quota_percent =
        if user_config.bandwidth_quota_bytes > 0,
          do: quota_used_bytes / user_config.bandwidth_quota_bytes * 100,
          else: 0

      spawn(fn -> send_quota_notifications(user_config, quota_percent) end)

      new_status =
        if quota_percent > 105 && user_config.status == "active" do
          "suspended"
        else
          user_config.status
        end

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
        from(uc in UserConfig, where: uc.id == ^user_config.id)
        |> Repo.update_all(set: updates)

      if new_status != user_config.status do
        Elektrine.VPN.PeerCache.invalidate(user_config.vpn_server_id)
      end

      result
    end
  end

  defp send_quota_notifications(user_config, quota_percent) do
    user = Repo.get!(Elektrine.Accounts.User, user_config.user_id)
    last_notification = get_in(user_config.metadata, ["last_quota_notification"]) || 0

    cond do
      quota_percent >= 100 && last_notification < 100 ->
        Elektrine.Platform.Integrations.send_vpn_quota_notification(:suspended, user, user_config)
        update_notification_metadata(user_config, 100)

      quota_percent >= 90 && last_notification < 90 ->
        Elektrine.Platform.Integrations.send_vpn_quota_notification(
          :warning,
          user,
          user_config,
          90
        )

        update_notification_metadata(user_config, 90)

      quota_percent >= 80 && last_notification < 80 ->
        Elektrine.Platform.Integrations.send_vpn_quota_notification(
          :warning,
          user,
          user_config,
          80
        )

        update_notification_metadata(user_config, 80)

      true ->
        :ok
    end
  end

  defp update_notification_metadata(user_config, threshold) do
    new_metadata = Map.put(user_config.metadata || %{}, "last_quota_notification", threshold)

    from(uc in UserConfig, where: uc.id == ^user_config.id)
    |> Repo.update_all(set: [metadata: new_metadata])
  end

  ## Connection Log functions

  @doc """
  Creates a connection log entry.
  """
  def create_connection_log(attrs \\ %{}) do
    %ConnectionLog{}
    |> ConnectionLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a connection log (e.g., when disconnecting).
  """
  def update_connection_log(%ConnectionLog{} = log, attrs) do
    log
    |> ConnectionLog.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets connection logs for a user config.
  """
  def list_connection_logs(user_config_id, limit \\ 50) do
    from(cl in ConnectionLog,
      where: cl.vpn_user_config_id == ^user_config_id,
      order_by: [desc: cl.connected_at],
      limit: ^limit
    )
    |> Repo.all()
  end
end
