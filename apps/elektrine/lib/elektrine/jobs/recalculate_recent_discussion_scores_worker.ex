defmodule Elektrine.Jobs.RecalculateRecentDiscussionScoresWorker do
  @moduledoc """
  Oban worker that refreshes discussion ranking scores for recent social posts.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Elektrine.Social.recalculate_recent_discussion_scores() do
      {:ok, result} ->
        Logger.info(
          "RecalculateRecentDiscussionScoresWorker: updated discussion scores #{inspect(result)}"
        )

        :ok

      {:error, reason} ->
        Logger.error("RecalculateRecentDiscussionScoresWorker failed: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  def enqueue do
    %{}
    |> new()
    |> Elektrine.JobQueue.insert()
  end
end
