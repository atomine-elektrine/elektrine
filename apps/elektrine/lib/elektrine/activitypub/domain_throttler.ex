defmodule Elektrine.ActivityPub.DomainThrottler do
  @moduledoc """
  Per-domain throttling for ActivityPub processing, similar to Lemmy's approach.

  Lemmy uses one queue per federated instance with configurable concurrent sends.
  This module provides similar functionality by:
  - Limiting concurrent processing per domain (default: 1)
  - Tracking failed domains with exponential backoff
  - Preventing one noisy instance from overwhelming the system
  """

  use GenServer
  require Logger

  # Max concurrent jobs per domain (reduced for performance)
  @max_concurrent_per_domain 2
  # Base delay for exponential backoff (2 seconds)
  @base_backoff_ms 2_000
  # Max backoff delay (2 minutes)
  @max_backoff_ms 120_000
  # After this many consecutive failures, apply backoff
  @failure_threshold 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempt to acquire a processing slot for a domain.
  Returns {:ok, :acquired} if slot available, {:error, :throttled} otherwise.
  """
  def acquire(domain) when is_binary(domain) do
    GenServer.call(__MODULE__, {:acquire, domain})
  end

  @doc """
  Release a processing slot for a domain.
  Call this when done processing an activity from the domain.
  """
  def release(domain, success? \\ true) when is_binary(domain) do
    GenServer.cast(__MODULE__, {:release, domain, success?})
  end

  @doc """
  Check if a domain is currently in backoff due to failures.
  """
  def in_backoff?(domain) when is_binary(domain) do
    GenServer.call(__MODULE__, {:in_backoff?, domain})
  end

  @doc """
  Get the current delay for a domain (0 if no backoff).
  """
  def get_delay(domain) when is_binary(domain) do
    GenServer.call(__MODULE__, {:get_delay, domain})
  end

  @doc """
  Get stats about current throttling state.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # ETS table for concurrent counts per domain
    :ets.new(:domain_concurrent, [:named_table, :public, :set])
    # ETS table for failure tracking
    :ets.new(:domain_failures, [:named_table, :public, :set])

    Logger.info(
      "DomainThrottler started (max #{@max_concurrent_per_domain} concurrent per domain)"
    )

    {:ok, %{}}
  end

  @impl true
  def handle_call({:acquire, domain}, _from, state) do
    now = System.system_time(:millisecond)

    # Check if domain is in backoff
    case :ets.lookup(:domain_failures, domain) do
      [{^domain, failures, last_failure, _last_success}] when failures >= @failure_threshold ->
        backoff_ms = calculate_backoff(failures)
        time_since_failure = now - last_failure

        if time_since_failure < backoff_ms do
          # Still in backoff period
          {:reply, {:error, :backoff, backoff_ms - time_since_failure}, state}
        else
          # Backoff expired, try to acquire
          try_acquire(domain, state)
        end

      _ ->
        try_acquire(domain, state)
    end
  end

  def handle_call({:in_backoff?, domain}, _from, state) do
    now = System.system_time(:millisecond)

    result =
      case :ets.lookup(:domain_failures, domain) do
        [{^domain, failures, last_failure, _}] when failures >= @failure_threshold ->
          backoff_ms = calculate_backoff(failures)
          now - last_failure < backoff_ms

        _ ->
          false
      end

    {:reply, result, state}
  end

  def handle_call({:get_delay, domain}, _from, state) do
    now = System.system_time(:millisecond)

    delay =
      case :ets.lookup(:domain_failures, domain) do
        [{^domain, failures, last_failure, _}] when failures >= @failure_threshold ->
          backoff_ms = calculate_backoff(failures)
          remaining = backoff_ms - (now - last_failure)
          max(0, remaining)

        _ ->
          0
      end

    {:reply, delay, state}
  end

  def handle_call(:stats, _from, state) do
    concurrent = :ets.tab2list(:domain_concurrent)

    failures =
      :ets.tab2list(:domain_failures)
      |> Enum.filter(fn {_domain, count, _last_fail, _last_success} ->
        count >= @failure_threshold
      end)

    stats = %{
      active_domains: length(concurrent),
      domains_in_backoff: length(failures),
      max_concurrent_per_domain: @max_concurrent_per_domain
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:release, domain, success?}, state) do
    # Decrement concurrent count
    case :ets.lookup(:domain_concurrent, domain) do
      [{^domain, count}] when count > 0 ->
        if count == 1 do
          :ets.delete(:domain_concurrent, domain)
        else
          :ets.insert(:domain_concurrent, {domain, count - 1})
        end

      _ ->
        :ok
    end

    # Update failure tracking
    now = System.system_time(:millisecond)

    if success? do
      # Reset or decrement failure count on success
      case :ets.lookup(:domain_failures, domain) do
        [{^domain, failures, last_failure, _last_success}] ->
          if failures > 0 do
            :ets.insert(:domain_failures, {domain, max(0, failures - 1), last_failure, now})
          end

        _ ->
          :ok
      end
    else
      # Increment failure count
      case :ets.lookup(:domain_failures, domain) do
        [{^domain, failures, _last_failure, last_success}] ->
          :ets.insert(:domain_failures, {domain, failures + 1, now, last_success})

        _ ->
          :ets.insert(:domain_failures, {domain, 1, now, 0})
      end
    end

    {:noreply, state}
  end

  # Private functions

  defp try_acquire(domain, state) do
    current =
      case :ets.lookup(:domain_concurrent, domain) do
        [{^domain, count}] -> count
        _ -> 0
      end

    if current < @max_concurrent_per_domain do
      :ets.insert(:domain_concurrent, {domain, current + 1})
      {:reply, {:ok, :acquired}, state}
    else
      {:reply, {:error, :throttled}, state}
    end
  end

  defp calculate_backoff(failures) do
    # Exponential backoff: base * 2^(failures - threshold)
    exponent = failures - @failure_threshold
    delay = @base_backoff_ms * :math.pow(2, exponent)
    min(round(delay), @max_backoff_ms)
  end
end
