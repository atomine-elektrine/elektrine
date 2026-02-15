defmodule Elektrine.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :elektrine
  @default_migration_pool_size 2
  @default_migration_timeout_ms 120_000
  @default_retry_attempts 30
  @default_retry_delay_ms 3_000

  def migrate do
    load_app()

    for repo <- repos() do
      with_db_retry(fn ->
        {:ok, _, _} =
          Ecto.Migrator.with_repo(
            repo,
            &Ecto.Migrator.run(&1, :up, all: true),
            migration_repo_opts()
          )
      end)
    end
  end

  def rollback(repo, version) do
    load_app()

    with_db_retry(fn ->
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          &Ecto.Migrator.run(&1, :down, to: version),
          migration_repo_opts()
        )
    end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp migration_repo_opts do
    opts = [
      pool_size: env_int("MIGRATION_POOL_SIZE", @default_migration_pool_size),
      queue_target: env_int("MIGRATION_QUEUE_TARGET_MS", 10_000),
      queue_interval: env_int("MIGRATION_QUEUE_INTERVAL_MS", 10_000),
      timeout: env_int("MIGRATION_TIMEOUT_MS", @default_migration_timeout_ms),
      pool_timeout: env_int("MIGRATION_POOL_TIMEOUT_MS", 30_000),
      connect_timeout: env_int("MIGRATION_CONNECT_TIMEOUT_MS", 60_000)
    ]

    case System.get_env("MIGRATION_DATABASE_URL") do
      nil -> opts
      "" -> opts
      migration_database_url -> Keyword.put(opts, :url, migration_database_url)
    end
  end

  defp with_db_retry(fun, attempt \\ 1) do
    max_attempts = env_int("MIGRATION_DB_RETRIES", @default_retry_attempts)
    delay_ms = env_int("MIGRATION_RETRY_DELAY_MS", @default_retry_delay_ms)

    try do
      fun.()
    rescue
      exception in [DBConnection.ConnectionError, Postgrex.Error] ->
        if attempt < max_attempts do
          IO.puts(
            "Migration attempt #{attempt}/#{max_attempts} failed: #{Exception.message(exception)}"
          )

          Process.sleep(delay_ms)
          with_db_retry(fun, attempt + 1)
        else
          reraise exception, __STACKTRACE__
        end
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> int
          _ -> default
        end
    end
  end

  defp load_app do
    Application.load(@app)
  end
end
