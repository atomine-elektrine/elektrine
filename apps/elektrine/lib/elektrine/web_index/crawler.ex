defmodule Elektrine.WebIndex.Crawler do
  @moduledoc "Polite crawl pipeline for HTML pages and declared XML sitemaps."

  alias Elektrine.WebIndex
  alias Elektrine.WebIndex.{Document, Extractor, Fetcher, Robots, SitemapWorker}

  @robots_ttl_seconds 12 * 60 * 60
  @default_delay_ms 1_000

  def crawl_document(document_id, opts \\ []) do
    case WebIndex.get_document(document_id) do
      nil ->
        {:discard, :document_not_found}

      %Document{} = document ->
        with :ok <- within_depth(document),
             {:ok, policy} <- policy(document.url, document.host, opts),
             true <- Robots.allowed?(policy, document.url),
             :ok <- reserve_host(document.host, Robots.crawl_delay_ms(policy), opts),
             {:ok, document} <- WebIndex.mark_fetching(document) do
          fetch_document(document, opts)
        else
          false -> block(document, :robots_disallowed)
          {:snooze, _seconds} = snooze -> snooze
          {:error, reason} -> fail(document, reason)
        end
    end
  end

  def crawl_sitemap(url, depth, opts \\ []) do
    with {:ok, normalized_url, host} <- WebIndex.normalize_url(url),
         {:ok, _host_record} <- WebIndex.ensure_host(host),
         {:ok, policy} <- policy(normalized_url, host, opts),
         true <- Robots.allowed?(policy, normalized_url),
         :ok <- reserve_host(host, Robots.crawl_delay_ms(policy), opts),
         {:ok, %{status: 200, body: body}} <-
           Fetcher.get(
             normalized_url,
             Keyword.put(opts, :accept, "application/xml,text/xml,*/*;q=0.1")
           ) do
      body
      |> sitemap_locations()
      |> Enum.each(&schedule_sitemap_location(&1, host, depth, opts))

      :ok
    else
      false -> {:discard, :robots_disallowed}
      {:snooze, _seconds} = snooze -> snooze
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_document(document, opts) do
    case Fetcher.get(document.url, opts) do
      {:ok, %{status: 200} = response} -> index_response(document, response, opts)
      {:ok, %{status: status}} when status in [404, 410] -> gone(document, status)
      {:ok, %{status: 401}} -> block(document, :http_401)
      {:ok, %{status: 403}} -> block(document, :http_403)
      {:ok, %{status: 429, headers: headers}} -> throttle(document, headers)
      {:ok, %{status: status}} -> fail(document, {:http_status, status}, %{http_status: status})
      {:error, reason} -> fail(document, reason)
    end
  end

  defp index_response(document, response, opts) do
    if html_response?(response.headers) do
      with {:ok, extracted} <- Extractor.extract(response.body, response.url),
           :ok <- indexable(extracted) do
        attrs = %{
          canonical_url: extracted.canonical_url,
          title: extracted.title || document.host,
          description: extracted.description,
          content: extracted.content,
          content_hash: extracted.content_hash,
          language: extracted.language,
          http_status: 200
        }

        case WebIndex.store_page(document, attrs) do
          {:ok, stored} ->
            discover_links(stored, extracted.links, opts)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, :noindex} -> noindex(document)
        {:error, reason} -> fail(document, reason)
      end
    else
      noindex(document, :unsupported_content_type)
    end
  end

  defp policy(url, host, opts) do
    record = WebIndex.robots_for(host)

    if fresh_robots?(record) do
      {:ok, Robots.parse(record.robots_body || "")}
    else
      fetch_robots(url, host, record, opts)
    end
  end

  defp fetch_robots(url, host, record, opts) do
    delay = if record, do: record.crawl_delay_ms, else: @default_delay_ms

    with :ok <- reserve_host(host, delay, opts),
         robots_url <- robots_url(url),
         {:ok, response} <-
           Fetcher.get(
             robots_url,
             opts
             |> Keyword.put(:accept, "text/plain,*/*;q=0.1")
             |> Keyword.put(:max_body_bytes, 512_000)
           ),
         {:ok, body} <- robots_body(response),
         parsed <- Robots.parse(body),
         crawl_delay <- Robots.crawl_delay_ms(parsed, delay),
         {:ok, _record} <- WebIndex.store_robots(host, robots_url, body, crawl_delay) do
      schedule_sitemaps(Robots.sitemaps(parsed), host, opts)

      if Keyword.get(opts, :pacing?, true) do
        {:snooze, max(div(crawl_delay + 999, 1_000), 1)}
      else
        {:ok, parsed}
      end
    end
  end

  defp robots_body(%{status: 200, body: body}), do: {:ok, body}

  defp robots_body(%{status: 429, headers: headers}),
    do: {:snooze, retry_after_seconds(headers)}

  defp robots_body(%{status: status}) when status in [401, 403],
    do: {:ok, "User-agent: *\nDisallow: /"}

  defp robots_body(%{status: status}) when status in 400..499, do: {:ok, ""}
  defp robots_body(%{status: status}), do: {:error, {:robots_http_status, status}}

  defp fresh_robots?(nil), do: false

  defp fresh_robots?(%{robots_fetched_at: nil}), do: false

  defp fresh_robots?(%{robots_fetched_at: fetched_at}) do
    DateTime.diff(DateTime.utc_now(), fetched_at, :second) < @robots_ttl_seconds
  end

  defp reserve_host(host, delay, opts) when is_list(opts) do
    if Keyword.get(opts, :pacing?, true) do
      case WebIndex.claim_host(host, delay) do
        :ok -> :ok
        seconds when is_integer(seconds) -> {:snooze, seconds}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp within_depth(%Document{depth: depth}) do
    if depth <= max_depth(), do: :ok, else: {:error, :maximum_depth}
  end

  defp indexable(%{noindex?: true}), do: {:error, :noindex}
  defp indexable(%{content: content}) when byte_size(content) < 40, do: {:error, :empty_content}
  defp indexable(_extracted), do: :ok

  defp discover_links(%Document{depth: depth} = stored, links, opts) do
    if depth < max_depth() do
      Enum.each(links, fn link ->
        _result =
          WebIndex.seed(link,
            depth: depth + 1,
            discovered_from: stored.canonical_url,
            enqueue?: Keyword.get(opts, :enqueue_discovered?, true)
          )
      end)
    end
  end

  defp schedule_sitemaps(urls, host, opts) do
    if Keyword.get(opts, :enqueue_discovered?, true) do
      urls
      |> Enum.take(10)
      |> Enum.each(fn url ->
        case WebIndex.normalize_url(url) do
          {:ok, normalized, ^host} ->
            _result =
              Oban.insert(
                SitemapWorker.new(%{url: normalized, depth: 0},
                  unique: [period: 3_600, fields: [:worker, :args]]
                )
              )

          _invalid_or_external ->
            :ok
        end
      end)
    end
  end

  defp schedule_sitemap_location(url, host, depth, opts) do
    case WebIndex.normalize_url(url) do
      {:ok, normalized, ^host} ->
        if sitemap_url?(normalized) and depth < 2 and
             Keyword.get(opts, :enqueue_discovered?, true) do
          _result =
            Oban.insert(
              SitemapWorker.new(%{url: normalized, depth: depth + 1},
                unique: [period: 3_600, fields: [:worker, :args]]
              )
            )
        else
          _result =
            WebIndex.seed(normalized,
              depth: 0,
              enqueue?: Keyword.get(opts, :enqueue_discovered?, true)
            )
        end

      _invalid_or_external ->
        :ok
    end
  end

  defp sitemap_locations(body) do
    case Floki.parse_document(body) do
      {:ok, tree} -> tree |> Floki.find("loc") |> Enum.map(&Floki.text/1) |> Enum.take(1_000)
      {:error, _reason} -> []
    end
  end

  defp robots_url(url) do
    uri = URI.parse(url)
    %{uri | path: "/robots.txt", query: nil, fragment: nil} |> URI.to_string()
  end

  defp sitemap_url?(url),
    do: url |> URI.parse() |> Map.get(:path) |> to_string() |> String.ends_with?(".xml")

  defp html_response?(headers) do
    case header(headers, "content-type") do
      nil ->
        true

      content_type ->
        String.starts_with?(String.downcase(content_type), ["text/html", "application/xhtml+xml"])
    end
  end

  defp header(headers, wanted) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == wanted, do: value
    end)
  end

  defp retry_after_seconds(headers) do
    case header(headers, "retry-after") do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {seconds, ""} when seconds > 0 -> min(seconds, 3_600)
          _invalid -> 60
        end

      _missing ->
        60
    end
  end

  defp gone(document, status) do
    _result =
      WebIndex.mark_status(document, "gone", %{http_status: status, last_error: "HTTP #{status}"})

    :ok
  end

  defp block(document, reason) do
    _result = WebIndex.mark_status(document, "blocked", %{last_error: inspect(reason)})
    {:discard, reason}
  end

  defp noindex(document, reason \\ :noindex) do
    _result = WebIndex.mark_status(document, "noindex", %{last_error: inspect(reason)})
    :ok
  end

  defp throttle(document, headers) do
    seconds = retry_after_seconds(headers)
    next_fetch_at = DateTime.add(DateTime.utc_now(:microsecond), seconds, :second)

    _result =
      WebIndex.mark_status(document, "failed", %{
        http_status: 429,
        last_error: "HTTP 429",
        next_fetch_at: next_fetch_at
      })

    {:snooze, seconds}
  end

  defp fail(document, reason, attrs \\ %{}) do
    attrs = Map.put(attrs, :last_error, inspect(reason))
    _result = WebIndex.mark_status(document, "failed", attrs)
    {:error, reason}
  end

  defp max_depth do
    :elektrine |> Application.get_env(:web_index, []) |> Keyword.get(:max_depth, 2)
  end
end
