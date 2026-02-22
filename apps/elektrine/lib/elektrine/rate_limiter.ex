defmodule Elektrine.RateLimiter do
  @moduledoc """
  Unified rate limiting functionality for all Elektrine systems.

  Uses ETS with GenServer for reliable, fast, in-memory rate limiting with automatic cleanup.

  ## Features

  - Multiple time windows (minute, hour, day)
  - Configurable lockout on threshold breach
  - Automatic cleanup of expired entries
  - Standardized error format
  - Per-identifier tracking (IP, user_id, etc.)

  ## Usage

  Define a rate limiter by using this module:

      defmodule MyApp.Auth.RateLimiter do
        use Elektrine.RateLimiter,
          table: :auth_rate_limit,
          limits: [
            {:minute, 5},
            {:hour, 10}
          ],
          lockout: {:minutes, 30},
          cleanup_interval: {:minutes, 5}
      end

  Then call functions:

      MyApp.Auth.RateLimiter.check_rate_limit("user@example.com")
      MyApp.Auth.RateLimiter.record_attempt("user@example.com")
      MyApp.Auth.RateLimiter.clear_limits("user@example.com")
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use GenServer
      require Logger

      @table_name Keyword.fetch!(opts, :table)
      @limits Keyword.get(opts, :limits, [])
      @lockout Keyword.get(opts, :lockout)
      @cleanup_interval Keyword.get(opts, :cleanup_interval, {:minutes, 5})

      # Convert limits to standard format: [{window_seconds, max_attempts}, ...]
      @parsed_limits Enum.map(@limits, fn
                       {:minute, max} ->
                         {60, max}

                       {:hour, max} ->
                         {3600, max}

                       {:day, max} ->
                         {86_400, max}

                       {window_seconds, max} when is_integer(window_seconds) ->
                         {window_seconds, max}
                     end)

      # Convert lockout duration to seconds
      @lockout_seconds (case @lockout do
                          nil -> nil
                          {:seconds, n} -> n
                          {:minutes, n} -> n * 60
                          {:hours, n} -> n * 3600
                          {:days, n} -> n * 86_400
                          n when is_integer(n) -> n
                        end)

      # Convert cleanup interval to milliseconds
      @cleanup_ms (case @cleanup_interval do
                     {:seconds, n} -> n * 1000
                     {:minutes, n} -> n * 60 * 1000
                     {:hours, n} -> n * 3600 * 1000
                     n when is_integer(n) -> n
                   end)

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @impl true
      def init(_opts) do
        table = :ets.new(@table_name, [:named_table, :public, :set])

        # Schedule cleanup
        if @cleanup_ms > 0 do
          Process.send_after(self(), :cleanup, @cleanup_ms)
        end

        {:ok, %{table: table}}
      end

      @impl true
      def handle_info(:cleanup, state) do
        cleanup_expired_entries()

        # Schedule next cleanup
        if @cleanup_ms > 0 do
          Process.send_after(self(), :cleanup, @cleanup_ms)
        end

        {:noreply, state}
      end

      @doc """
      Checks if an identifier can proceed based on rate limits.

      Returns:
      - `{:ok, :allowed}` - Can proceed
      - `{:error, {:rate_limited, retry_after_seconds, reason}}` - Rate limited
      """
      def check_rate_limit(identifier) do
        case :ets.lookup(@table_name, identifier) do
          [] ->
            {:ok, :allowed}

          [{^identifier, attempts, locked_until}] ->
            now = System.system_time(:second)

            # Check if locked out
            if locked_until && now < locked_until do
              retry_after = locked_until - now
              {:error, {:rate_limited, retry_after, :locked_out}}
            else
              # Check each rate limit window
              check_limits(attempts, now)
            end
        end
      end

      @doc """
      Records an attempt for rate limiting.
      Automatically locks out if limits exceeded.
      """
      def record_attempt(identifier) do
        now = System.system_time(:second)

        case :ets.lookup(@table_name, identifier) do
          [] ->
            # First attempt
            :ets.insert(@table_name, {identifier, [now], nil})

          [{^identifier, attempts, _locked_until}] ->
            # Add new attempt and filter old ones
            new_attempts = [now | filter_recent_attempts(attempts, now)]

            # Check if we should lock out
            locked_until = calculate_lockout(new_attempts, now)

            if locked_until do
              Logger.warning(
                "Rate limit lockout for #{identifier} until #{DateTime.from_unix!(locked_until)}"
              )
            end

            :ets.insert(@table_name, {identifier, new_attempts, locked_until})
        end

        :ok
      end

      @doc """
      Clears all rate limiting data for an identifier.
      Typically called on successful authentication.
      """
      def clear_limits(identifier) do
        :ets.delete(@table_name, identifier)
        :ok
      end

      @doc """
      Gets the current rate limit status for an identifier.
      """
      def get_status(identifier) do
        case :ets.lookup(@table_name, identifier) do
          [] ->
            %{
              locked: false,
              locked_until: nil,
              attempts: %{}
            }

          [{^identifier, attempts, locked_until}] ->
            now = System.system_time(:second)

            attempt_counts =
              Enum.map(@parsed_limits, fn {window, max} ->
                recent = count_recent(attempts, now, window)
                {window, %{count: recent, limit: max, remaining: max(0, max - recent)}}
              end)
              |> Map.new()

            %{
              locked: locked_until && now < locked_until,
              locked_until: locked_until,
              attempts: attempt_counts
            }
        end
      end

      @doc """
      Returns the configuration for this rate limiter.
      """
      def config do
        %{
          table: @table_name,
          limits: @limits,
          lockout: @lockout,
          cleanup_interval: @cleanup_interval
        }
      end

      # Private functions

      defp check_limits(attempts, now) do
        # Check each limit window
        violation =
          Enum.find_value(@parsed_limits, fn {window_seconds, max_attempts} ->
            recent_count = count_recent(attempts, now, window_seconds)

            if recent_count >= max_attempts do
              {window_seconds, recent_count, max_attempts}
            end
          end)

        case violation do
          nil ->
            {:ok, :allowed}

          {window_seconds, count, max} ->
            reason = format_limit_reason(window_seconds, count, max)
            {:error, {:rate_limited, window_seconds, reason}}
        end
      end

      defp count_recent(attempts, now, window_seconds) do
        cutoff = now - window_seconds
        Enum.count(attempts, fn timestamp -> timestamp > cutoff end)
      end

      defp filter_recent_attempts(attempts, now) do
        # Keep attempts from the largest window
        max_window =
          @parsed_limits
          |> Enum.map(fn {window, _} -> window end)
          |> Enum.max(fn -> 3600 end)

        cutoff = now - max_window
        Enum.filter(attempts, fn timestamp -> timestamp > cutoff end)
      end

      if @lockout_seconds do
        defp calculate_lockout(attempts, now) do
          # Check if any limit is exceeded
          exceeded? =
            Enum.any?(@parsed_limits, fn {window_seconds, max_attempts} ->
              count_recent(attempts, now, window_seconds) >= max_attempts
            end)

          if exceeded? do
            now + @lockout_seconds
          else
            nil
          end
        end
      else
        defp calculate_lockout(_attempts, _now), do: nil
      end

      defp format_limit_reason(60, count, max), do: "#{count}/#{max} attempts in last minute"
      defp format_limit_reason(3600, count, max), do: "#{count}/#{max} attempts in last hour"
      defp format_limit_reason(86_400, count, max), do: "#{count}/#{max} attempts in last day"

      defp format_limit_reason(seconds, count, max),
        do: "#{count}/#{max} attempts in last #{seconds}s"

      defp cleanup_expired_entries do
        now = System.system_time(:second)

        # Get the longest window we care about
        max_window =
          @parsed_limits
          |> Enum.map(fn {window, _} -> window end)
          |> Enum.max(fn -> 3600 end)

        # Double it for safety margin
        cutoff = now - max_window * 2

        # Get all entries and clean up old ones
        :ets.tab2list(@table_name)
        |> Enum.each(fn {identifier, attempts, locked_until} ->
          # Remove if all attempts are old and not locked
          oldest_attempt = List.last(attempts)

          if oldest_attempt && oldest_attempt < cutoff && (!locked_until || now >= locked_until) do
            :ets.delete(@table_name, identifier)
          else
            # Clean up old attempts from the list
            recent_attempts = Enum.filter(attempts, fn t -> t > cutoff end)

            if recent_attempts != attempts do
              new_locked_until =
                if locked_until && now >= locked_until, do: nil, else: locked_until

              :ets.insert(@table_name, {identifier, recent_attempts, new_locked_until})
            end
          end
        end)
      end

      # Allow overriding in child modules
      defoverridable check_rate_limit: 1, record_attempt: 1, clear_limits: 1, get_status: 1
    end
  end
end
