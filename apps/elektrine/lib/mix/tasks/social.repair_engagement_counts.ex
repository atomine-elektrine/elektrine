defmodule Mix.Tasks.Social.RepairEngagementCounts do
  @moduledoc """
  Repairs cached social engagement counters.

  Usage:

      mix social.repair_engagement_counts
      mix social.repair_engagement_counts --dry-run
      mix social.repair_engagement_counts --limit 10000 --batch-size 500
  """

  use Mix.Task

  alias Elektrine.Social.EngagementCountRepair

  @shortdoc "Repairs cached social engagement counters"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, limit: :integer, batch_size: :integer],
        aliases: [n: :limit]
      )

    dry_run? = Keyword.get(opts, :dry_run, false)
    limit = Keyword.get(opts, :limit)
    batch_size = Keyword.get(opts, :batch_size, 500)

    Mix.shell().info("Repairing engagement counts#{if dry_run?, do: " (dry run)", else: ""}...")

    progress_fun = fn %{seen: seen, changed: changed} ->
      Mix.shell().info("Scanned #{seen}; changed #{changed}...")
    end

    %{seen: seen, changed: changed} =
      EngagementCountRepair.run(
        dry_run: dry_run?,
        limit: limit,
        batch_size: batch_size,
        progress_fun: progress_fun
      )

    Mix.shell().info("Done. Scanned #{seen} messages; #{changed} would change/changed.")
  end
end
