defmodule Elektrine.DB.WriteGuard do
  @moduledoc """
  Utilities for best-effort writes in contexts that may become read-only.

  Use this for non-critical writes (tracking/telemetry timestamps, last-used markers)
  where authentication or request processing should continue if the database session
  is read-only.
  """

  alias Elektrine.Repo
  require Logger

  @default_fallback {:error, :read_only_sql_transaction}

  @doc """
  Runs `write_fun` and gracefully degrades on PostgreSQL read-only transaction errors.

  ## Options

    * `:on_read_only` - return value used when write is skipped/fails due to
      read-only transaction (`{:error, :read_only_sql_transaction}` by default).
      Can be a value or a zero-arity function.

  """
  def run(operation, write_fun, opts \\ [])
      when is_binary(operation) and is_function(write_fun, 0) do
    fallback = Keyword.get(opts, :on_read_only, @default_fallback)

    if Repo.in_transaction?() and read_only_transaction_mode?() do
      log_skip(operation)
      fallback_value(fallback)
    else
      try do
        write_fun.()
      rescue
        error in Postgrex.Error ->
          if read_only_sql_transaction?(error) do
            log_skip(operation)
            fallback_value(fallback)
          else
            reraise(error, __STACKTRACE__)
          end
      end
    end
  end

  defp fallback_value(fallback) when is_function(fallback, 0), do: fallback.()
  defp fallback_value(fallback), do: fallback

  defp log_skip(operation) do
    Logger.warning("Skipped #{operation}: read-only SQL transaction")
  end

  defp read_only_sql_transaction?(%Postgrex.Error{
         postgres: %{code: :read_only_sql_transaction}
       }),
       do: true

  defp read_only_sql_transaction?(%Postgrex.Error{}), do: false

  defp read_only_transaction_mode? do
    case Repo.query("SHOW transaction_read_only", []) do
      {:ok, %{rows: [[mode]]}} -> mode == "on"
      _ -> false
    end
  end
end
