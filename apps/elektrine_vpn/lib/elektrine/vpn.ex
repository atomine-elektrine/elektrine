defmodule Elektrine.VPN do
  @moduledoc """
  The VPN context - handles WireGuard VPN server and user configuration management.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.VPN.{Server, UserConfig, ConnectionLog}

  require Logger

  ## Server functions

  @doc """
  Returns the list of VPN servers.
  """
  def list_servers do
    Repo.all(Server)
  end

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
    |> Server.changeset(attrs)
    |> Repo.insert()
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
      |> Map.put_new(:endpoint_port, 51820)
      |> Map.put_new(:dns_servers, "1.1.1.1, 1.0.0.1")
      |> Map.put_new(:internal_ip_range, "10.8.0.0/24")

    case create_server(attrs) do
      {:ok, server} ->
        Logger.info("Auto-registered new VPN server: #{server.name} (ID: #{server.id})")
        {:ok, server}

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

  @doc """
  Updates a server.
  """
  def update_server(%Server{} = server, attrs) do
    server
    |> Server.changeset(attrs)
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
    with {:ok, _server} <- get_available_server(server_id),
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

          {:ok, Repo.preload(config, [:vpn_server])}

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
        end

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

    """
    [Interface]
    PrivateKey = #{private_key}
    Address = #{config.allocated_ip}
    DNS = #{server.dns_servers}

    [Peer]
    PublicKey = #{server.public_key}
    Endpoint = #{server.public_ip}:#{server.endpoint_port}
    AllowedIPs = #{config.allowed_ips}
    PersistentKeepalive = #{config.persistent_keepalive}
    """
  end

  ## Helper functions

  defp get_available_server(server_id) do
    server = Repo.get(Server, server_id)

    cond do
      is_nil(server) ->
        {:error, :server_not_found}

      server.status != "active" ->
        {:error, :server_not_active}

      true ->
        {:ok, server}
    end
  end

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
