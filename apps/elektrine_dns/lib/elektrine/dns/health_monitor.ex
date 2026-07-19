defmodule Elektrine.DNS.HealthMonitor do
  @moduledoc """
  Liveness checks for failover-enrolled A/AAAA records.

  A record opts in through its metadata:

      %{"health_check" => %{"enabled" => true, "port" => 443}}

  Enrolled targets are TCP-checked on an interval. An address is marked
  down after #{2} consecutive failures and recovers on the first success.
  The authoritative query path (`Elektrine.DNS.Query`) drops downed
  addresses from answers — unless every candidate for a name is down, in
  which case all are returned (fail-open: a broken health check must never
  empty an answer set).

  Unknown targets are considered healthy, so the monitor being disabled or
  not yet warmed up never affects answers.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Elektrine.DNS.Record
  alias Elektrine.Repo

  @table :elektrine_dns_health_status
  @default_interval_ms 30_000
  @connect_timeout_ms 3_000
  @default_port 443
  @down_after 2
  @max_concurrency 16

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Whether a target address:port is currently considered healthy.
  Unknown targets (and a missing monitor) are healthy by default.
  """
  def healthy?(address, port \\ @default_port) do
    case :ets.lookup(@table, {address, port}) do
      [{_key, :down, _fails}] -> false
      _ -> true
    end
  rescue
    ArgumentError -> true
  end

  @doc "Current health table as a map of {address, port} => :up | :down."
  def snapshot do
    @table
    |> :ets.tab2list()
    |> Map.new(fn {key, status, _fails} -> {key, status} end)
  rescue
    ArgumentError -> %{}
  end

  @doc "Run a sweep immediately (used by tests and admin tooling)."
  def check_now(server \\ __MODULE__) do
    GenServer.call(server, :check, 30_000)
  end

  @doc false
  def default_port, do: @default_port

  @impl true
  def init(opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    interval = Keyword.get(opts, :interval_ms, env_interval())

    state = %{
      interval: interval,
      targets_fun: Keyword.get(opts, :targets_fun, &enrolled_targets/0)
    }

    unless interval == :manual do
      Process.send_after(self(), :check, interval)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:check, _from, state) do
    sweep(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    sweep(state)
    Process.send_after(self(), :check, state.interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp sweep(state) do
    targets = state.targets_fun.()

    prune_departed(targets)

    targets
    |> Task.async_stream(&probe/1,
      max_concurrency: @max_concurrency,
      timeout: @connect_timeout_ms + 2_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(targets)
    |> Enum.each(fn
      {{:ok, result}, target} -> record_result(target, result)
      {{:exit, _reason}, target} -> record_result(target, :error)
    end)
  rescue
    error ->
      Logger.warning("DNS health sweep failed: #{Exception.message(error)}")
  end

  defp probe({address, port}) do
    with {:ok, ip} <- :inet.parse_address(String.to_charlist(address)),
         {:ok, socket} <-
           :gen_tcp.connect(ip, port, [:binary, active: false], @connect_timeout_ms) do
      :gen_tcp.close(socket)
      :ok
    else
      _ -> :error
    end
  end

  defp record_result(target, :ok) do
    :ets.insert(@table, {target, :up, 0})
  end

  defp record_result(target, :error) do
    fails =
      case :ets.lookup(@table, target) do
        [{_key, _status, fails}] -> fails + 1
        [] -> 1
      end

    status = if fails >= @down_after, do: :down, else: :up

    if status == :down do
      {address, port} = target
      Logger.warning("DNS health: marking #{address}:#{port} down after #{fails} failures")
    end

    :ets.insert(@table, {target, status, fails})
  end

  # Forget targets that are no longer enrolled so stale entries cannot
  # affect answers if a record is re-added later.
  defp prune_departed(targets) do
    keep = MapSet.new(targets)

    for {key, _status, _fails} <- :ets.tab2list(@table),
        not MapSet.member?(keep, key) do
      :ets.delete(@table, key)
    end
  end

  defp enrolled_targets do
    from(r in Record,
      where: r.type in ["A", "AAAA"],
      where: fragment("?::jsonb -> 'health_check' ->> 'enabled' IN ('true', 't')", r.metadata),
      select: {r.content, r.metadata}
    )
    |> Repo.all()
    |> Enum.map(fn {address, metadata} -> {address, health_check_port(metadata)} end)
    |> Enum.uniq()
  rescue
    error ->
      Logger.warning("DNS health target load failed: #{Exception.message(error)}")
      []
  end

  @doc false
  def health_check_port(metadata) when is_map(metadata) do
    case get_in(metadata, ["health_check", "port"]) do
      port when is_integer(port) and port in 1..65_535 -> port
      port when is_binary(port) -> parse_port(port)
      _ -> @default_port
    end
  end

  def health_check_port(_metadata), do: @default_port

  defp parse_port(value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> port
      _ -> @default_port
    end
  end

  defp env_interval do
    case System.get_env("DNS_HEALTH_CHECK_INTERVAL_MS") do
      nil ->
        @default_interval_ms

      value ->
        case Integer.parse(value) do
          {ms, ""} when ms >= 1_000 -> ms
          _ -> @default_interval_ms
        end
    end
  end
end
