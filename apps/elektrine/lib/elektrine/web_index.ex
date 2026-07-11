defmodule Elektrine.WebIndex do
  @moduledoc """
  Storage, scheduling, and full-text retrieval for Paige's independent web index.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Repo
  alias Elektrine.WebIndex.{CrawlWorker, Document, Host}

  @default_limit 10
  @max_limit 50
  @max_url_bytes 4_096

  @doc "Adds a public HTTP(S) URL to the frontier and schedules it for crawling."
  def seed(url, opts \\ []) do
    with {:ok, canonical_url, host} <- normalize_url(url),
         {:ok, _host} <- ensure_host(host),
         {:ok, document} <- upsert_document(canonical_url, host, opts),
         :ok <- maybe_enqueue(document, opts) do
      {:ok, document}
    end
  end

  @doc "Searches indexed documents using PostgreSQL's weighted English full-text index."
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) do
    query = String.trim(query)
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()
    page = opts |> Keyword.get(:page, 1) |> normalize_page()

    if query == "" do
      []
    else
      from(document in Document,
        where: document.status == "indexed",
        where: fragment("search_vector @@ websearch_to_tsquery('english', ?)", ^query),
        order_by: [
          desc:
            fragment(
              "ts_rank_cd(search_vector, websearch_to_tsquery('english', ?), 32)",
              ^query
            ),
          desc: document.fetched_at,
          asc: document.id
        ],
        limit: ^limit,
        offset: ^((page - 1) * limit),
        select: %{
          title: document.title,
          url: document.canonical_url,
          description: document.description,
          content: document.content,
          fetched_at: document.fetched_at,
          language: document.language,
          score:
            fragment(
              "ts_rank_cd(search_vector, websearch_to_tsquery('english', ?), 32)",
              ^query
            )
        }
      )
      |> Repo.all()
    end
  end

  def search(_query, _opts), do: []

  @doc false
  def get_document(id), do: Repo.get(Document, id)

  @doc false
  def mark_fetching(%Document{} = document) do
    document
    |> Document.changeset(%{status: "fetching", attempts: document.attempts + 1})
    |> Repo.update()
  end

  @doc false
  def store_page(%Document{} = document, attrs) do
    now = DateTime.utc_now(:microsecond)
    content_hash = Map.fetch!(attrs, :content_hash)
    canonical_url = Map.get(attrs, :canonical_url, document.canonical_url)

    Repo.transaction(fn ->
      content_duplicate =
        from(other in Document,
          where: other.id != ^document.id,
          where: other.status == "indexed",
          where: other.content_hash == ^content_hash,
          select: other.id,
          limit: 1
        )
        |> Repo.one()

      canonical_duplicate =
        from(other in Document,
          where: other.id != ^document.id,
          where: other.canonical_url == ^canonical_url,
          select: other.id,
          limit: 1
        )
        |> Repo.one()

      duplicate = content_duplicate || canonical_duplicate
      status = if duplicate, do: "duplicate", else: "indexed"

      attrs =
        if duplicate,
          do: Map.delete(attrs, :canonical_url),
          else: Map.put(attrs, :canonical_url, canonical_url)

      document
      |> Document.changeset(
        attrs
        |> Map.put(:status, status)
        |> Map.put(:fetched_at, now)
        |> Map.put(:next_fetch_at, DateTime.add(now, recrawl_seconds(), :second))
        |> Map.put(:last_error, nil)
      )
      |> Repo.update!()
    end)
  end

  @doc false
  def mark_status(%Document{} = document, status, attrs \\ %{}) do
    now = DateTime.utc_now(:microsecond)

    document
    |> Document.changeset(
      attrs
      |> Map.put(:status, status)
      |> Map.put_new(:fetched_at, now)
      |> Map.put_new(:next_fetch_at, DateTime.add(now, retry_seconds(status), :second))
    )
    |> Repo.update()
  end

  @doc false
  def robots_for(host), do: Repo.get(Host, host)

  @doc false
  def store_robots(host, url, body, crawl_delay_ms) do
    now = DateTime.utc_now(:microsecond)

    host
    |> robots_for()
    |> Host.changeset(%{
      robots_url: url,
      robots_body: body,
      robots_fetched_at: now,
      crawl_delay_ms: crawl_delay_ms
    })
    |> Repo.update()
  end

  @doc "Atomically reserves the host's next request slot across all application nodes."
  def claim_host(host, delay_ms) do
    Repo.transaction(fn ->
      record = Repo.one!(from item in Host, where: item.host == ^host, lock: "FOR UPDATE")
      now = DateTime.utc_now(:microsecond)

      if record.next_allowed_at && DateTime.compare(record.next_allowed_at, now) == :gt do
        max(DateTime.diff(record.next_allowed_at, now, :second), 1)
      else
        next_allowed_at = DateTime.add(now, delay_ms, :millisecond)

        record
        |> Host.changeset(%{next_allowed_at: next_allowed_at, crawl_delay_ms: delay_ms})
        |> Repo.update!()

        :ok
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def enqueue_due(limit \\ 100) do
    now = DateTime.utc_now(:microsecond)

    from(document in Document,
      where: document.status in ["pending", "failed", "fetching", "indexed"],
      where: is_nil(document.next_fetch_at) or document.next_fetch_at <= ^now,
      order_by: [asc: document.next_fetch_at, asc: document.id],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.reduce(0, fn document, count ->
      case enqueue(document) do
        :ok -> count + 1
        {:error, _reason} -> count
      end
    end)
  end

  @doc false
  def normalize_url(url) when is_binary(url) do
    url = String.trim(url)

    if byte_size(url) > @max_url_bytes or String.match?(url, ~r/[\x00-\x20\x7F]/u) do
      {:error, :invalid_url}
    else
      uri = URI.parse(url)
      scheme = if is_binary(uri.scheme), do: String.downcase(uri.scheme)

      if scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
           uri.userinfo in [nil, ""] do
        host = String.downcase(uri.host)
        path = normalize_path(uri.path)
        port = normalize_port(scheme, uri.port)
        query = normalize_query(uri.query)
        {:ok, "#{scheme}://#{host}#{port}#{path}#{query}", host}
      else
        {:error, :invalid_url}
      end
    end
  rescue
    _error -> {:error, :invalid_url}
  end

  def normalize_url(_url), do: {:error, :invalid_url}

  @doc false
  def ensure_host(host) do
    %Host{}
    |> Host.changeset(%{host: host})
    |> Repo.insert(on_conflict: :nothing, conflict_target: :host)
    |> case do
      {:ok, %Host{host: nil}} -> {:ok, Repo.get!(Host, host)}
      result -> result
    end
  end

  defp upsert_document(url, host, opts) do
    attrs = %{
      url: url,
      canonical_url: url,
      host: host,
      depth: Keyword.get(opts, :depth, 0),
      discovered_from: Keyword.get(opts, :discovered_from)
    }

    %Document{}
    |> Document.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:url, :updated_at]},
      conflict_target: :canonical_url,
      returning: true
    )
  end

  defp maybe_enqueue(document, opts) do
    if Keyword.get(opts, :enqueue?, true), do: enqueue(document), else: :ok
  end

  defp enqueue(%Document{} = document) do
    %{document_id: document.id}
    |> CrawlWorker.new(unique: [period: 300, fields: [:worker, :args]])
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp normalize_limit(_limit), do: @default_limit
  defp normalize_page(page) when is_integer(page), do: max(page, 1)
  defp normalize_page(_page), do: 1

  defp normalize_path(path) when path in [nil, ""], do: "/"
  defp normalize_path(path), do: path
  defp normalize_port("http", port) when port in [nil, 80], do: ""
  defp normalize_port("https", port) when port in [nil, 443], do: ""
  defp normalize_port(_scheme, nil), do: ""
  defp normalize_port(_scheme, port), do: ":#{port}"

  defp normalize_query(query) when query in [nil, ""], do: ""

  defp normalize_query(query) do
    params =
      query
      |> URI.query_decoder()
      |> Enum.reject(fn {key, _value} -> tracking_parameter?(key) end)
      |> Enum.sort()

    if params == [], do: "", else: "?#{URI.encode_query(params)}"
  rescue
    _error -> "?#{query}"
  end

  defp tracking_parameter?(key) do
    key = String.downcase(key)
    String.starts_with?(key, "utm_") or key in ["fbclid", "gclid", "mc_cid", "mc_eid"]
  end

  defp recrawl_seconds do
    :elektrine
    |> Application.get_env(:web_index, [])
    |> Keyword.get(:recrawl_seconds, 7 * 24 * 60 * 60)
  end

  defp retry_seconds("indexed"), do: recrawl_seconds()
  defp retry_seconds("gone"), do: 30 * 24 * 60 * 60
  defp retry_seconds("blocked"), do: 7 * 24 * 60 * 60
  defp retry_seconds("noindex"), do: 7 * 24 * 60 * 60
  defp retry_seconds(_status), do: 60 * 60
end
