defmodule ElektrineWeb.WebSearch do
  @moduledoc """
  Cached front-end for Paige web search.

  Results are cached per normalized query and result-affecting option set so
  repeat searches don't hit the paid provider APIs again. Cache keys contain a
  query digest rather than the raw search text, and concurrent identical misses
  are coalesced. Degraded or unconfigured responses are returned but not cached,
  so provider trouble does not pin incomplete results for the whole TTL.
  """

  alias Elektrine.AppCache

  @default_limit 10
  @max_page 10

  @spec search(String.t(), keyword()) ::
          {:ok, [Paige.Result.t()], map()} | {:error, term()}
  def search(query, opts \\ []) do
    query = normalize_query(query)
    search_opts = normalize_search_opts(opts)

    if cache_enabled?() and is_binary(query) do
      cached_search(query, search_opts)
    else
      Paige.search_detailed(query, search_opts)
    end
  end

  defp cached_search(query, search_opts) do
    cache_opts = Keyword.drop(search_opts, [:provider_timeout, :timeout])
    cache_key = {:v2, query_hash(query), cache_opts}

    # AppCache intentionally does not coalesce generic misses because many of
    # its callbacks can be invoked from DB transactions. Paige fetches only
    # remote HTTP data, so a per-key lock is safe here and prevents identical
    # concurrent misses from multiplying paid provider calls. Each waiter
    # re-enters AppCache after acquiring the lock and therefore sees the value
    # committed by the first fetcher.
    :global.trans({{__MODULE__, cache_key}, self()}, fn ->
      AppCache.get_web_search_results(cache_key, fn ->
        case Paige.search_detailed(query, search_opts) do
          {:ok, _results, %{degraded?: false, available?: true}} = success ->
            {:commit, success}

          other ->
            {:ignore, other}
        end
      end)
    end)
  end

  # Keep the provider call and the cache identity on the same normalized
  # contract. Adding a result-affecting option to one without the other can
  # serve a cached page/filter variant for a different request.
  defp normalize_search_opts(opts) do
    kind = opts |> Keyword.get(:kind, :web) |> Paige.Kind.normalize()

    [
      kind: kind,
      limit: normalize_limit(Keyword.get(opts, :limit, @default_limit), kind),
      page: normalize_page(Keyword.get(opts, :page, 1)),
      freshness: normalize_freshness(Keyword.get(opts, :freshness)),
      safesearch: normalize_safesearch(Keyword.get(opts, :safesearch), kind),
      country: normalize_text_option(Keyword.get(opts, :country), "us"),
      search_lang: normalize_text_option(Keyword.get(opts, :search_lang), "en"),
      spellcheck: normalize_spellcheck(Keyword.get(opts, :spellcheck, 1))
    ]
    |> maybe_put_operational_option(:provider_timeout, opts)
    |> maybe_put_operational_option(:timeout, opts)
  end

  defp normalize_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  defp normalize_query(query), do: query

  defp query_hash(query) do
    query
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp normalize_limit(limit, kind) when is_integer(limit) do
    max_limit = if kind == :images, do: 200, else: 50
    limit |> max(1) |> min(max_limit)
  end

  defp normalize_limit(_limit, _kind), do: @default_limit

  defp normalize_page(page) when is_integer(page), do: page |> max(1) |> min(@max_page)

  defp normalize_page(page) when is_binary(page) do
    case Integer.parse(String.trim(page)) do
      {parsed, ""} -> normalize_page(parsed)
      _error -> 1
    end
  end

  defp normalize_page(_page), do: 1

  defp normalize_freshness(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_freshness()

  defp normalize_freshness(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      "all" -> nil
      "day" -> "pd"
      "week" -> "pw"
      "month" -> "pm"
      "year" -> "py"
      value when value in ["pd", "pw", "pm", "py"] -> value
      value -> if valid_date_range?(value), do: value
    end
  end

  defp normalize_freshness(_value), do: nil

  defp normalize_safesearch(value, kind) do
    default = if kind == :images, do: "strict", else: "moderate"

    normalized =
      case value do
        value when is_atom(value) ->
          value |> Atom.to_string() |> normalize_safesearch_value(default)

        value when is_binary(value) ->
          normalize_safesearch_value(value, default)

        _value ->
          default
      end

    if kind == :images and normalized == "moderate", do: "strict", else: normalized
  end

  defp normalize_safesearch_value(value, default) do
    case value |> String.trim() |> String.downcase() do
      value when value in ["off", "moderate", "strict"] -> value
      _value -> default
    end
  end

  defp normalize_text_option(value, default) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> default
      value -> value
    end
  end

  defp normalize_text_option(_value, default), do: default

  defp normalize_spellcheck(value) when value in [false, 0], do: 0

  defp normalize_spellcheck(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in ["0", "false", "off"], do: 0, else: 1
  end

  defp normalize_spellcheck(_value), do: 1

  defp valid_date_range?(value) do
    case String.split(value, "to", parts: 2) do
      [start_date, end_date] -> valid_iso_date?(start_date) and valid_iso_date?(end_date)
      _parts -> false
    end
  end

  defp valid_iso_date?(value), do: match?({:ok, %Date{}}, Date.from_iso8601(value))

  # Timeouts influence availability rather than result identity. They are
  # forwarded to Paige but omitted from `cache_opts` in `cached_search/2`.
  defp maybe_put_operational_option(search_opts, key, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Keyword.put(search_opts, key, value)
      :error -> search_opts
    end
  end

  defp cache_enabled? do
    Application.get_env(:elektrine_web, :web_search_cache_enabled, true)
  end
end
