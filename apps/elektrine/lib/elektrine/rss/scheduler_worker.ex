defmodule Elektrine.RSS.SchedulerWorker do
  @moduledoc """
  Oban worker that runs periodically to enqueue fetch jobs for stale RSS feeds.
  """
  use Oban.Worker, queue: :rss, max_attempts: 1

  alias Elektrine.RSS
  alias Elektrine.RSS.FetchFeedWorker

  @impl Oban.Worker
  def perform(_job) do
    jobs =
      RSS.list_stale_feeds(50)
      |> Enum.map(fn feed ->
        %{feed_id: feed.id}
        |> FetchFeedWorker.new()
      end)

    if jobs != [] do
      _ = Elektrine.JobQueue.insert_all(jobs)
    end

    :ok
  end
end
