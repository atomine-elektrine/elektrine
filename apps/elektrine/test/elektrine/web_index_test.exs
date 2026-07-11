defmodule Elektrine.WebIndexTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Repo
  alias Elektrine.WebIndex
  alias Elektrine.WebIndex.{Crawler, Document, Provider}

  test "crawls, extracts, stores, and searches a seeded page" do
    url = unique_url("guide")
    assert {:ok, document} = WebIndex.seed(url, enqueue?: false)

    request_fun = fn requested_url, _headers, _opts ->
      if String.ends_with?(requested_url, "/robots.txt") do
        response(200, "User-agent: PaigeBot\nAllow: /", "text/plain")
      else
        response(
          200,
          """
          <html lang="en"><head><title>Paige Independent Index</title>
          <meta name="description" content="Search without depending on one upstream engine"></head>
          <body><main>Paige crawls selected websites and ranks useful independent documents.</main></body></html>
          """,
          "text/html; charset=utf-8"
        )
      end
    end

    assert :ok =
             Crawler.crawl_document(document.id,
               request_fun: request_fun,
               pacing?: false,
               enqueue_discovered?: false
             )

    stored = Repo.get!(Document, document.id)
    assert stored.status == "indexed"
    assert stored.title == "Paige Independent Index"
    assert stored.content_hash

    assert [result] = WebIndex.search("independent documents")
    assert result.url == url

    assert {:ok, [provider_result]} = Provider.search("independent documents")
    assert provider_result.source == "Paige Index"
    assert provider_result.metadata.independent_index
  end

  test "robots exclusions prevent a page fetch and mark it blocked" do
    url = unique_url("private/report")
    assert {:ok, document} = WebIndex.seed(url, enqueue?: false)
    test_pid = self()

    request_fun = fn requested_url, _headers, _opts ->
      send(test_pid, {:requested, requested_url})
      response(200, "User-agent: *\nDisallow: /private/", "text/plain")
    end

    assert {:discard, :robots_disallowed} =
             Crawler.crawl_document(document.id,
               request_fun: request_fun,
               pacing?: false,
               enqueue_discovered?: false
             )

    assert_received {:requested, robots_url}
    assert String.ends_with?(robots_url, "/robots.txt")
    refute_received {:requested, ^url}
    assert Repo.get!(Document, document.id).status == "blocked"
  end

  test "declared sitemaps add same-host locations to the frontier" do
    root = unique_url("")
    host = URI.parse(root).host
    sitemap_url = "https://#{host}/sitemap.xml"
    page_url = "https://#{host}/from-sitemap"

    request_fun = fn requested_url, _headers, _opts ->
      case URI.parse(requested_url).path do
        "/robots.txt" ->
          response(200, "User-agent: *\nAllow: /", "text/plain")

        "/sitemap.xml" ->
          response(200, "<urlset><url><loc>#{page_url}</loc></url></urlset>", "application/xml")
      end
    end

    assert :ok =
             Crawler.crawl_sitemap(sitemap_url, 0,
               request_fun: request_fun,
               pacing?: false,
               enqueue_discovered?: false
             )

    assert Repo.get_by(Document, canonical_url: page_url)
  end

  test "content hashes prevent duplicate copies from entering search" do
    first =
      index_page(
        unique_url("first"),
        "Original",
        "Shared body long enough to index as a useful document"
      )

    second =
      index_page(
        unique_url("second"),
        "Copy",
        "Shared body long enough to index as a useful document"
      )

    assert first.status == "indexed"
    assert second.status == "duplicate"
    assert length(WebIndex.search("Shared body")) == 1
  end

  test "normalizes URLs and rejects credentials or unsupported schemes" do
    assert {:ok, "https://example.com/path?q=1", "example.com"} =
             WebIndex.normalize_url(" https://EXAMPLE.com:443/path?utm_source=test&q=1#fragment ")

    assert {:error, :invalid_url} = WebIndex.normalize_url("file:///etc/passwd")
    assert {:error, :invalid_url} = WebIndex.normalize_url("https://user:pass@example.com/")
    assert {:error, :invalid_url} = WebIndex.normalize_url("https://example.com/a path")
  end

  defp index_page(url, title, content) do
    assert {:ok, document} = WebIndex.seed(url, enqueue?: false)

    assert {:ok, stored} =
             WebIndex.store_page(document, %{
               title: title,
               description: nil,
               content: content,
               content_hash: :crypto.hash(:sha256, content),
               language: "en",
               http_status: 200
             })

    stored
  end

  defp unique_url(path) do
    unique = System.unique_integer([:positive])
    "https://site#{unique}.example/#{path}"
  end

  defp response(status, body, content_type) do
    {:ok, %{status: status, body: body, headers: [{"content-type", content_type}]}}
  end
end
