defmodule Mix.Tasks.Secrets.Backfill do
  @moduledoc "Encrypts legacy plaintext secret fields in place."
  @shortdoc "Encrypts legacy plaintext secret fields in place"

  use Mix.Task

  alias Elektrine.Secrets.Backfill

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    dry_run? = not Enum.member?(args, "--apply")
    result = Backfill.run(dry_run: dry_run?)

    Mix.shell().info("Secrets backfill #{if(dry_run?, do: "dry-run", else: "applied")}")
    Mix.shell().info("Scanned: #{result.scanned}")
    Mix.shell().info("Updated: #{result.updated}")

    Enum.each(result.fields, fn {name, stats} ->
      Mix.shell().info("#{name}: scanned=#{stats.scanned} updated=#{stats.updated}")
    end)

    if dry_run? do
      Mix.shell().info("Run with --apply to persist encrypted values.")
    end
  end
end
