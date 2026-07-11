defmodule Elektrine.WebIndex.CrawlWorker do
  @moduledoc "Oban worker for one independent-index page fetch."

  use Oban.Worker, queue: :crawler, max_attempts: 4

  alias Elektrine.WebIndex.Crawler

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => document_id}}) do
    Crawler.crawl_document(document_id)
  end
end
