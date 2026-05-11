defmodule Elektrine.Social.ScheduledPostPublisherWorker do
  @moduledoc "Publishes scheduled social drafts whose scheduled time has arrived."

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias Elektrine.Social.Drafts

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{published: published, failed: failed} = Drafts.publish_due_scheduled_drafts(limit: 100)

    if published > 0 or failed > 0 do
      Logger.info("Scheduled social post publisher: published=#{published} failed=#{failed}")
    end

    :ok
  end
end
