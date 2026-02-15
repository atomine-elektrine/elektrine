defmodule Elektrine.SMTP.SendRateLimiter do
  @moduledoc """
  IP-based rate limiting for SMTP email sends.

  This limits how many emails can be sent from a single IP address,
  regardless of which user accounts are used. This prevents bot networks
  from creating many accounts to bypass per-user limits.

  Limits:
  - 5 emails per minute per IP
  - 30 emails per hour per IP
  - 100 emails per day per IP
  """

  use GenServer
  require Logger

  @table_name :smtp_send_rate_limiter
  @cleanup_interval :timer.minutes(5)

  # Very strict limits per IP
  @minute_limit 5
  @hour_limit 30
  @day_limit 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set])
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_entries()
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:noreply, state}
  end

  @doc """
  Checks if an IP can send an email.

  Returns:
  - `{:ok, :allowed}` - Can send
  - `{:error, :ip_rate_limited}` - IP has exceeded send limits
  """
  def check_send_limit(ip_address) when is_binary(ip_address) do
    now = System.system_time(:second)
    attempts = get_attempts(ip_address)

    minute_count = count_recent(attempts, now, 60)
    hour_count = count_recent(attempts, now, 3600)
    day_count = count_recent(attempts, now, 86400)

    cond do
      minute_count >= @minute_limit ->
        Logger.warning(
          "SMTP SendRateLimiter: IP #{ip_address} exceeded minute limit: #{minute_count}/#{@minute_limit}"
        )

        {:error, :ip_rate_limited}

      hour_count >= @hour_limit ->
        Logger.warning(
          "SMTP SendRateLimiter: IP #{ip_address} exceeded hourly limit: #{hour_count}/#{@hour_limit}"
        )

        {:error, :ip_rate_limited}

      day_count >= @day_limit ->
        Logger.warning(
          "SMTP SendRateLimiter: IP #{ip_address} exceeded daily limit: #{day_count}/#{@day_limit}"
        )

        {:error, :ip_rate_limited}

      true ->
        {:ok, :allowed}
    end
  end

  @doc """
  Records a successful email send from an IP.
  """
  def record_send(ip_address) when is_binary(ip_address) do
    now = System.system_time(:second)

    case :ets.lookup(@table_name, ip_address) do
      [] ->
        :ets.insert(@table_name, {ip_address, [now]})

      [{^ip_address, attempts}] ->
        # Filter old attempts and add new one
        cutoff = now - 86400
        filtered = Enum.filter(attempts, fn ts -> ts > cutoff end)
        new_attempts = [now | filtered]
        :ets.insert(@table_name, {ip_address, new_attempts})
    end

    :ok
  end

  @doc """
  Gets the current status for an IP.
  """
  def get_status(ip_address) do
    now = System.system_time(:second)
    attempts = get_attempts(ip_address)

    %{
      minute: %{
        count: count_recent(attempts, now, 60),
        limit: @minute_limit,
        remaining: max(0, @minute_limit - count_recent(attempts, now, 60))
      },
      hour: %{
        count: count_recent(attempts, now, 3600),
        limit: @hour_limit,
        remaining: max(0, @hour_limit - count_recent(attempts, now, 3600))
      },
      day: %{
        count: count_recent(attempts, now, 86400),
        limit: @day_limit,
        remaining: max(0, @day_limit - count_recent(attempts, now, 86400))
      }
    }
  end

  # Private functions

  defp get_attempts(ip_address) do
    case :ets.lookup(@table_name, ip_address) do
      [] -> []
      [{^ip_address, attempts}] -> attempts
    end
  end

  defp count_recent(attempts, now, window_seconds) do
    cutoff = now - window_seconds
    Enum.count(attempts, fn timestamp -> timestamp > cutoff end)
  end

  defp cleanup_expired_entries do
    now = System.system_time(:second)
    cutoff = now - 86400 * 2

    :ets.tab2list(@table_name)
    |> Enum.each(fn {ip, attempts} ->
      filtered = Enum.filter(attempts, fn ts -> ts > cutoff end)

      if Enum.empty?(filtered) do
        :ets.delete(@table_name, ip)
      else
        :ets.insert(@table_name, {ip, filtered})
      end
    end)
  end
end
