defmodule Mix.Tasks.Social.BackfillLemmyCommentVotes do
  @moduledoc false
  use Mix.Task

  alias Elektrine.ActivityPub.LemmyCommentBackfill

  @shortdoc "Backfills stored Lemmy comment vote counts"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    start_task_services()

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean],
        aliases: [d: :dry_run]
      )

    if invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(invalid)}")
    end

    dry_run? = Keyword.get(opts, :dry_run, false)
    result = LemmyCommentBackfill.run(dry_run: dry_run?)

    Mix.shell().info("Lemmy comment vote backfill")
    Mix.shell().info("  Dry run: #{dry_run?}")
    Mix.shell().info("  Lemmy posts scanned: #{result.posts}")
    Mix.shell().info("  Comments updated: #{result.comments}")
    Mix.shell().info("  Remote count refreshes: #{result.remote_comments}")
    Mix.shell().info("  Fallback upvote seeds: #{result.fallback_comments}")
  end

  defp start_task_services do
    Enum.each(
      [:crypto, :ssl, :inets, :telemetry, :ecto, :ecto_sql, :postgrex, :phoenix_pubsub],
      fn app ->
        {:ok, _} = Application.ensure_all_started(app)
      end
    )

    {:ok, _pid} =
      Supervisor.start_link(
        [
          Elektrine.Repo,
          {Phoenix.PubSub, name: Elektrine.PubSub},
          {Finch, name: Elektrine.Finch}
        ],
        strategy: :one_for_one
      )
  end
end
