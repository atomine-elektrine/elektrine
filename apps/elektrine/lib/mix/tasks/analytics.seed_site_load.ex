defmodule Mix.Tasks.Analytics.SeedSiteLoad do
  @shortdoc "Seeds synthetic site analytics traffic for local performance testing"

  @moduledoc """
  Seeds synthetic `site_sessions` and `site_page_visits` rows for local analytics testing.

  This task is intended for development and test databases only. It writes rows with
  a synthetic user agent so they can be deleted safely afterward.

  Examples:

      mix analytics.seed_site_load --host elektrine.com --sessions 100000 --visits 1000000 --clean --benchmark
      mix analytics.seed_site_load --host elektrine.com --only-clean

  Options:

    * `--host` - request host to seed, defaults to `elektrine.com`
    * `--visits` - number of `site_page_visits` rows, defaults to `1_000_000`
    * `--sessions` - number of `site_sessions` rows, defaults to `100_000`
    * `--batch-size` - insert batch size, defaults to `50_000`
    * `--clean` - delete existing synthetic rows for the host before seeding
    * `--only-clean` - delete existing synthetic rows for the host and exit
    * `--benchmark` - time the domain analytics functions after seeding
  """

  use Mix.Task

  alias Ecto.Adapters.SQL
  alias Elektrine.{Profiles, Repo}

  @synthetic_user_agent "ElektrineSyntheticAnalyticsLoadTest/1.0"
  @default_host "elektrine.com"
  @default_visits 1_000_000
  @default_sessions 100_000
  @default_batch_size 50_000

  @switches [
    host: :string,
    visits: :integer,
    sessions: :integer,
    batch_size: :integer,
    clean: :boolean,
    only_clean: :boolean,
    benchmark: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    prevent_production!()
    start_repo!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    host = Keyword.get(opts, :host, @default_host)
    visits = Keyword.get(opts, :visits, @default_visits)
    sessions = Keyword.get(opts, :sessions, @default_sessions)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    validate_positive!(:visits, visits)
    validate_positive!(:sessions, sessions)
    validate_positive!(:batch_size, batch_size)

    sessions = min(sessions, visits)

    if Keyword.get(opts, :clean, false) or Keyword.get(opts, :only_clean, false) do
      clean_host(host)
    end

    unless Keyword.get(opts, :only_clean, false) do
      run_id = Integer.to_string(System.system_time(:millisecond))
      session_prefix = "synthetic:#{host}:#{run_id}"

      seed_sessions(host, session_prefix, sessions, visits, batch_size)
      seed_visits(host, session_prefix, sessions, visits, batch_size)

      Mix.shell().info("Seeded #{sessions} synthetic sessions and #{visits} visits for #{host}.")

      if Keyword.get(opts, :benchmark, false) do
        benchmark(host)
      end
    end
  end

  defp prevent_production! do
    if Mix.env() == :prod do
      Mix.raise("analytics.seed_site_load is disabled in prod")
    end
  end

  defp start_repo! do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Mix.raise("Failed to start repo: #{inspect(reason)}")
    end
  end

  defp validate_positive!(_name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(name, value) do
    Mix.raise(
      "--#{String.replace(to_string(name), "_", "-")} must be a positive integer, got #{inspect(value)}"
    )
  end

  defp clean_host(host) do
    Mix.shell().info("Deleting synthetic analytics rows for #{host}...")

    %{num_rows: visits_deleted} =
      query!(
        """
        DELETE FROM site_page_visits
        WHERE request_host = $1 AND user_agent = $2
        """,
        [host, @synthetic_user_agent]
      )

    %{num_rows: sessions_deleted} =
      query!(
        """
        DELETE FROM site_sessions
        WHERE entry_host = $1 AND user_agent = $2
        """,
        [host, @synthetic_user_agent]
      )

    Mix.shell().info("Deleted #{sessions_deleted} sessions and #{visits_deleted} visits.")
  end

  defp seed_sessions(host, session_prefix, sessions, visits, batch_size) do
    Mix.shell().info("Seeding #{sessions} synthetic sessions for #{host}...")

    for {first, last} <- ranges(sessions, batch_size) do
      query!(
        """
        INSERT INTO site_sessions (
          session_id,
          viewer_user_id,
          visitor_id,
          ip_address,
          user_agent,
          referer,
          entry_host,
          entry_path,
          exit_host,
          exit_path,
          page_views,
          started_at,
          last_seen_at,
          duration_seconds,
          inserted_at,
          updated_at
        )
        SELECT
          $1 || ':' || gs,
          NULL,
          'synthetic-visitor-' || gs,
          '203.0.113.' || ((gs % 250) + 1),
          $2,
          CASE WHEN gs % 5 = 0 THEN 'https://referrer.example/' || (gs % 25) ELSE NULL END,
          $3,
          CASE
            WHEN gs % 11 = 0 THEN '/pricing'
            WHEN gs % 7 = 0 THEN '/about'
            WHEN gs % 5 = 0 THEN '/portal'
            ELSE '/'
          END,
          $3,
          CASE
            WHEN gs % 13 = 0 THEN '/account'
            WHEN gs % 11 = 0 THEN '/pricing'
            WHEN gs % 7 = 0 THEN '/about'
            ELSE '/'
          END,
          (($4::bigint / $5::bigint) + CASE WHEN gs <= ($4::bigint % $5::bigint) THEN 1 ELSE 0 END)::integer,
          (timezone('UTC', now()) - ((gs % 2592000) * interval '1 second'))::timestamp(0),
          (timezone('UTC', now()) - ((gs % 2592000) * interval '1 second') + interval '30 seconds')::timestamp(0),
          (30 + (gs % 600))::integer,
          (timezone('UTC', now()) - ((gs % 2592000) * interval '1 second'))::timestamp(0),
          (timezone('UTC', now()) - ((gs % 2592000) * interval '1 second'))::timestamp(0)
        FROM generate_series($6::bigint, $7::bigint) AS gs
        """,
        [session_prefix, @synthetic_user_agent, host, visits, sessions, first, last]
      )
    end
  end

  defp seed_visits(host, session_prefix, sessions, visits, batch_size) do
    Mix.shell().info("Seeding #{visits} synthetic page visits for #{host}...")

    for {first, last} <- ranges(visits, batch_size) do
      query!(
        """
        INSERT INTO site_page_visits (
          session_id,
          viewer_user_id,
          visitor_id,
          ip_address,
          user_agent,
          referer,
          request_host,
          request_path,
          status,
          inserted_at
        )
        SELECT
          $1 || ':' || (((gs - 1) % $4::bigint) + 1),
          NULL,
          'synthetic-visitor-' || (((gs - 1) % $4::bigint) + 1),
          '203.0.113.' || ((gs % 250) + 1),
          $2,
          CASE WHEN gs % 5 = 0 THEN 'https://referrer.example/' || (gs % 25) ELSE NULL END,
          $3,
          CASE
            WHEN gs % 11 = 0 THEN '/pricing'
            WHEN gs % 7 = 0 THEN '/about'
            WHEN gs % 5 = 0 THEN '/portal'
            ELSE '/'
          END,
          200,
          (timezone('UTC', now()) - ((gs % 2592000) * interval '1 second'))::timestamp(0)
        FROM generate_series($5::bigint, $6::bigint) AS gs
        """,
        [session_prefix, @synthetic_user_agent, host, sessions, first, last]
      )
    end
  end

  defp ranges(total, batch_size) do
    Stream.iterate(1, &(&1 + batch_size))
    |> Stream.take_while(&(&1 <= total))
    |> Enum.map(fn first -> {first, min(first + batch_size - 1, total)} end)
  end

  defp benchmark(host) do
    Mix.shell().info("Benchmarking analytics functions for #{host}...")

    time("get_public_site_view_stats", fn -> Profiles.get_public_site_view_stats(host) end)

    time("get_public_site_daily_view_counts", fn ->
      Profiles.get_public_site_daily_view_counts(30, host)
    end)

    time("get_public_site_domain_breakdown", fn ->
      Profiles.get_public_site_domain_breakdown([host])
    end)

    time("get_public_site_top_pages", fn -> Profiles.get_public_site_top_pages(host, 10) end)

    time("get_public_site_top_referrers", fn ->
      Profiles.get_public_site_top_referrers(host, 10)
    end)
  end

  defp time(label, fun) do
    {duration_us, result} = :timer.tc(fun)
    Mix.shell().info("#{label}: #{Float.round(duration_us / 1000, 1)}ms #{summarize(result)}")
  end

  defp summarize(result) when is_list(result), do: "(#{length(result)} rows)"
  defp summarize(result) when is_map(result), do: inspect(result)
  defp summarize(_result), do: ""

  defp query!(sql, params) do
    SQL.query!(Repo, sql, params, timeout: :infinity, pool_timeout: :infinity)
  end
end
