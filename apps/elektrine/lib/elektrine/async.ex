defmodule Elektrine.Async do
  @moduledoc """
  Helper module for running code asynchronously in a way that's compatible
  with Ecto Sandbox in tests.

  In production, tasks run asynchronously using Task.start.
  In tests, tasks run synchronously to work with the database sandbox.

  ## Usage

      # Instead of:
      Task.start(fn -> do_something() end)

      # Use:
      Elektrine.Async.run(fn -> do_something() end)

  ## Configuration

  Set `:elektrine, :async_enabled` to false in config/test.exs:

      config :elektrine, :async_enabled, false
  """

  @doc """
  Runs a function asynchronously in production, synchronously in tests.

  In production (async_enabled: true), uses Task.start for fire-and-forget execution.
  In tests (async_enabled: false), runs synchronously to work with Ecto Sandbox.
  """
  def run(fun) when is_function(fun, 0) do
    if async_enabled?() do
      Task.start(fun)
    else
      # Run synchronously in tests, catching errors to match Task.start behavior
      try do
        fun.()
        {:ok, :completed}
      rescue
        _e -> {:ok, :error_ignored}
      end
    end
  end

  @doc """
  Starts a fire-and-forget task in production, skips it in tests.

  Use this for side-effects that shouldn't run during tests (network calls,
  background polling, analytics, cache warmers), while still keeping the same
  production behavior.
  """
  def start(fun) when is_function(fun, 0) do
    if async_enabled?() do
      Task.start(fun)
    else
      {:ok, :skipped}
    end
  end

  @doc """
  Checks if async execution is enabled (production) or disabled (tests).
  Defaults to true (async) if not configured.
  """
  def async_enabled? do
    Application.get_env(:elektrine, :async_enabled, true)
  end
end
