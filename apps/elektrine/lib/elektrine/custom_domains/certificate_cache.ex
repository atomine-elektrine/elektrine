defmodule Elektrine.CustomDomains.CertificateCache do
  @moduledoc """
  ETS-based cache for SSL certificates.

  Stores decoded certificates in memory for fast SNI lookups during TLS handshakes.
  Uses LRU eviction to limit memory usage.

  ## Cache Entry Format

  Each entry stores:
  - Certificate in DER format (for SSL)
  - Private key in DER format (for SSL)
  - PEM versions (for debugging/display)
  - Last access time (for LRU eviction)
  """

  use GenServer
  require Logger

  @table_name :custom_domain_certificates
  @max_entries 1000
  @cleanup_interval :timer.minutes(5)

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets certificate for a domain.

  Returns `{:ok, cert_der, key_der}` or `:error`.
  """
  def get(hostname) do
    hostname_lower = String.downcase(hostname)

    case :ets.lookup(@table_name, hostname_lower) do
      [{^hostname_lower, entry}] ->
        # Update access time
        :ets.update_element(@table_name, hostname_lower, {2, %{entry | accessed_at: now()}})
        {:ok, entry.cert_der, entry.key_der}

      [] ->
        # Try to load from database
        load_from_database(hostname_lower)
    end
  end

  @doc """
  Stores certificate in cache.

  Takes PEM-encoded certificate and private key.
  """
  def put(hostname, certificate_pem, private_key_pem) do
    GenServer.call(__MODULE__, {:put, hostname, certificate_pem, private_key_pem})
  end

  @doc """
  Removes certificate from cache.
  """
  def delete(hostname) do
    hostname_lower = String.downcase(hostname)
    :ets.delete(@table_name, hostname_lower)
    :ok
  end

  @doc """
  Clears all cached certificates.
  """
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Returns cache statistics.
  """
  def stats do
    %{
      entries: :ets.info(@table_name, :size),
      memory_bytes: :ets.info(@table_name, :memory) * :erlang.system_info(:wordsize)
    }
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table
    :ets.new(@table_name, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, hostname, certificate_pem, private_key_pem}, _from, state) do
    result = do_put(hostname, certificate_pem, private_key_pem)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_if_needed()
    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  defp do_put(hostname, certificate_pem, private_key_pem) do
    hostname_lower = String.downcase(hostname)

    with {:ok, cert_der} <- pem_to_der(certificate_pem, :certificate),
         {:ok, key_der} <- pem_to_der(private_key_pem, :private_key) do
      entry = %{
        cert_der: cert_der,
        key_der: key_der,
        cert_pem: certificate_pem,
        key_pem: private_key_pem,
        cached_at: now(),
        accessed_at: now()
      }

      :ets.insert(@table_name, {hostname_lower, entry})
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to cache certificate for #{hostname}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp load_from_database(hostname) do
    case Elektrine.CustomDomains.get_certificate_for_domain(hostname) do
      {:ok, cert_pem, key_pem} ->
        # Cache it for future lookups
        case do_put(hostname, cert_pem, key_pem) do
          :ok ->
            # Now fetch from cache to get DER format
            case :ets.lookup(@table_name, hostname) do
              [{^hostname, entry}] -> {:ok, entry.cert_der, entry.key_der}
              [] -> :error
            end

          {:error, _} ->
            :error
        end

      {:error, _} ->
        :error
    end
  end

  defp pem_to_der(pem, :certificate) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted}] ->
        {:ok, der}

      [entry | _] when elem(entry, 0) == :Certificate ->
        {:ok, elem(entry, 1)}

      _ ->
        {:error, :invalid_certificate}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  end

  defp pem_to_der(pem, :private_key) do
    case :public_key.pem_decode(pem) do
      [{type, der, :not_encrypted}]
      when type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo] ->
        {:ok, {type, der}}

      [{type, der, _}] when type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo] ->
        {:ok, {type, der}}

      _ ->
        {:error, :invalid_private_key}
    end
  rescue
    _ -> {:error, :invalid_private_key}
  end

  defp cleanup_if_needed do
    size = :ets.info(@table_name, :size)

    if size > @max_entries do
      # Evict oldest entries (by access time)
      entries_to_remove = size - @max_entries + div(@max_entries, 10)

      @table_name
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_hostname, entry} -> entry.accessed_at end)
      |> Enum.take(entries_to_remove)
      |> Enum.each(fn {hostname, _entry} ->
        :ets.delete(@table_name, hostname)
      end)

      Logger.info("Certificate cache cleanup: removed #{entries_to_remove} entries")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp now do
    System.monotonic_time(:millisecond)
  end
end
