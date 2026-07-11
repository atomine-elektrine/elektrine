defmodule Elektrine.WebIndex.SitemapWorker do
  @moduledoc "Oban worker for a robots-declared sitemap or sitemap index."

  use Oban.Worker, queue: :crawler, max_attempts: 4

  alias Elektrine.WebIndex.Crawler

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url, "depth" => depth}}) do
    Crawler.crawl_sitemap(url, depth)
  end
end
