defmodule Mix.Tasks.Activitypub.MigrateDomain do
  @moduledoc false
  use Mix.Task

  @shortdoc "Broadcast ActivityPub Move activities from an old domain to the current domain"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          from: :string,
          to: :string,
          dry_run: :boolean,
          usernames: :string,
          limit: :integer
        ],
        aliases: [f: :from, t: :to, d: :dry_run, u: :usernames, l: :limit]
      )

    usernames =
      opts
      |> Keyword.get(:usernames, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    migration_opts =
      []
      |> maybe_put(:from_domain, opts[:from])
      |> maybe_put(:to_domain, opts[:to])
      |> maybe_put(:limit, opts[:limit])
      |> Keyword.put(:dry_run, Keyword.get(opts, :dry_run, false))
      |> Keyword.put(:usernames, usernames)

    case Elektrine.ActivityPub.DomainMigration.broadcast_moves(migration_opts) do
      {:ok, summary} ->
        print_summary(summary)

      {:error, :missing_from_domain} ->
        Mix.raise("Missing source domain. Pass --from or set ACTIVITYPUB_MOVE_FROM_DOMAIN.")

      {:error, :missing_to_domain} ->
        Mix.raise("Missing target domain. Pass --to or set INSTANCE_DOMAIN.")

      {:error, :same_domain} ->
        Mix.raise("Source and target domains must be different.")

      {:error, reason} ->
        Mix.raise("Domain migration failed: #{inspect(reason)}")
    end
  end

  defp print_summary(summary) do
    Mix.shell().info("ActivityPub domain migration summary")
    Mix.shell().info("  From: #{summary.from_domain}")
    Mix.shell().info("  To: #{summary.to_domain}")
    Mix.shell().info("  Dry run: #{summary.dry_run}")
    Mix.shell().info("  Users processed: #{summary.users_processed}")

    Mix.shell().info(
      "  Users without remote followers: #{summary.users_without_remote_followers}"
    )

    Mix.shell().info("  Deliveries attempted: #{summary.deliveries_attempted}")
    Mix.shell().info("  Deliveries succeeded: #{summary.deliveries_succeeded}")
    Mix.shell().info("  Deliveries failed: #{summary.deliveries_failed}")

    if summary.deliveries_failed > 0 do
      Mix.shell().info("  Recent errors:")

      summary.errors
      |> Enum.take(20)
      |> Enum.reverse()
      |> Enum.each(fn error ->
        Mix.shell().info("    #{error.username} -> #{error.inbox} (#{error.reason})")
      end)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
