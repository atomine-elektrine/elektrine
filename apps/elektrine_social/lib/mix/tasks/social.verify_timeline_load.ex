defmodule Mix.Tasks.Social.VerifyTimelineLoad do
  @moduledoc """
  Seeds and verifies home timeline pagination under load.

  Usage:

      mix social.verify_timeline_load
      mix social.verify_timeline_load --count 120 --page-size 20
      mix social.verify_timeline_load --viewer timelineviewer --author timelineauthor
  """

  use Mix.Task

  alias Elektrine.Social.TimelineLoadVerifier

  @shortdoc "Seeds and verifies home timeline pagination"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          count: :integer,
          page_size: :integer,
          max_pages: :integer,
          viewer: :string,
          author: :string,
          prefix: :string
        ],
        aliases: [n: :count]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    verifier_opts =
      opts
      |> rename(:viewer, :viewer_username)
      |> rename(:author, :author_username)

    case TimelineLoadVerifier.run(verifier_opts) do
      {:ok, summary} ->
        Mix.shell().info("Timeline load verification passed")
        Mix.shell().info("  Viewer: #{summary.viewer_username} (#{summary.viewer_id})")
        Mix.shell().info("  Author: #{summary.author_username} (#{summary.author_id})")
        Mix.shell().info("  Seeded: #{summary.seeded_count}")
        Mix.shell().info("  Found: #{summary.found_count}/#{summary.expected_count}")
        Mix.shell().info("  Pages checked: #{summary.pages_checked}")
        Mix.shell().info("  Loaded rows: #{summary.loaded_count}")
        Mix.shell().info("  ID range: #{summary.first_id}..#{summary.last_id}")

      {:error, error} ->
        Mix.shell().error("Timeline load verification failed: #{inspect(error)}")
        System.halt(1)
    end
  end

  defp rename(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put(opts, to, value)
    end
  end
end
