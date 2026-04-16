defmodule Mix.Tasks.Activitypub.RepairSubmittedLinks do
  @moduledoc """
  Enqueue repair jobs for federated messages missing submitted links.
  """

  @shortdoc "Enqueue repair jobs for missing submitted links"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    limit =
      case args do
        [value | _] ->
          case Integer.parse(value) do
            {parsed, ""} when parsed > 0 -> parsed
            _ -> 100
          end

        _ ->
          100
      end

    case Elektrine.ActivityPub.SubmittedLinkRepairWorker.enqueue_batch(limit) do
      {:ok, _job} -> Mix.shell().info("Enqueued submitted link repair batch (limit=#{limit})")
      {:error, reason} -> Mix.raise("Failed to enqueue repair batch: #{inspect(reason)}")
    end
  end
end
