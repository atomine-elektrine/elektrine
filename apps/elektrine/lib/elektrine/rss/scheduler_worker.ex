defmodule Elektrine.RSS.SchedulerWorker do
  @moduledoc """
  Oban worker that runs periodically to enqueue fetch jobs for stale RSS feeds.
  """
  use Oban.Worker, queue: :rss, max_attempts: 1

  alias Elektrine.RSS
  alias Elektrine.RSS.FetchFeedWorker

  @impl Oban.Worker
  def perform(_job) do
    # Get feeds that haven't been fetched recently
    stale_feeds = RSS.list_stale_feeds(50)

    # Enqueue fetch jobs for each stale feed
    Enum.each(stale_feeds, fn feed ->
      %{feed_id: feed.id}
      |> FetchFeedWorker.new()
      |> Oban.insert()
    end)

    :ok
  end
end
