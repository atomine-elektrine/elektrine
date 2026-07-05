defmodule Paige do
  @moduledoc "Meta-search core for Paige."

  alias Paige.Kind
  alias Paige.Result

  @type provider_spec :: module() | {module(), keyword()}

  @default_provider_timeout_ms 6_000

  @doc "Searches configured providers and returns normalized, deduplicated results."
  def search(query, opts \\ []) do
    case search_detailed(query, opts) do
      {:ok, results, _meta} -> {:ok, results}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `search/2`, but also returns metadata about provider failures so
  callers can tell when results are degraded (some providers errored or
  timed out) instead of silently missing sources.
  """
  def search_detailed(query, opts \\ [])

  def search_detailed(query, opts) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {:error, :empty_query}
    else
      kind = opts |> Keyword.get(:kind, :web) |> Kind.normalize()

      providers =
        opts
        |> Keyword.get(:providers, configured_providers())
        |> Enum.filter(&provider_handles_kind?(&1, kind))

      limit = opts |> Keyword.get(:limit, 10) |> normalize_limit(kind)
      provider_call_opts = Keyword.drop(opts, [:providers])

      outcomes = run_providers(providers, query, provider_call_opts)

      results =
        outcomes
        |> Enum.flat_map(fn
          {_provider, {:ok, results}} -> results
          {_provider, {:error, _reason}} -> []
        end)
        |> dedupe_results()
        |> Enum.sort_by(&result_sort_key/1, :asc)
        |> Enum.take(limit)

      failed = for {provider, {:error, reason}} <- outcomes, do: {provider, reason}

      if results == [] and outcomes != [] and length(failed) == length(outcomes) do
        {:error, :providers_unavailable}
      else
        {:ok, results, %{failed_providers: failed, degraded?: failed != []}}
      end
    end
  end

  def search_detailed(_query, _opts), do: {:error, :invalid_query}

  defp configured_providers do
    :paige
    |> Application.get_env(:providers, [])
    |> List.wrap()
  end

  defp provider_handles_kind?({_module, provider_opts}, kind) when is_list(provider_opts) do
    case Keyword.get(provider_opts, :kinds) do
      kinds when is_list(kinds) -> kind in Enum.map(kinds, &Kind.normalize/1)
      _no_restriction -> true
    end
  end

  defp provider_handles_kind?(_provider, _kind), do: true

  defp run_providers([], _query, _call_opts), do: []

  defp run_providers(providers, query, call_opts) do
    providers
    |> Enum.with_index()
    |> Task.async_stream(
      fn {provider, index} -> search_provider(provider, query, index, call_opts) end,
      timeout: provider_timeout(call_opts),
      on_timeout: :kill_task,
      ordered: true,
      max_concurrency: length(providers)
    )
    |> Enum.zip(providers)
    |> Enum.map(fn
      {{:ok, outcome}, provider} -> {provider_module(provider), outcome}
      {{:exit, _reason}, provider} -> {provider_module(provider), {:error, :timeout}}
    end)
  end

  defp provider_timeout(opts) do
    Keyword.get(opts, :provider_timeout) ||
      Application.get_env(:paige, :provider_timeout, @default_provider_timeout_ms)
  end

  defp provider_module({module, _opts}) when is_atom(module), do: module
  defp provider_module(provider), do: provider

  defp normalize_limit(limit, kind) when is_integer(limit),
    do: limit |> max(1) |> min(max_limit(kind))

  defp normalize_limit(_limit, _kind), do: 10

  defp max_limit(:images), do: 200
  defp max_limit(_kind), do: 50

  defp search_provider({module, provider_opts}, query, index, call_opts) when is_atom(module) do
    run_provider(module, query, Keyword.merge(provider_opts, call_opts), index)
  end

  defp search_provider(module, query, index, call_opts) when is_atom(module) do
    run_provider(module, query, call_opts, index)
  end

  defp search_provider(_provider, _query, _index, _call_opts), do: {:error, :invalid_provider}

  defp run_provider(module, query, provider_opts, index) do
    case module.search(query, provider_opts) do
      {:ok, results} when is_list(results) ->
        normalized =
          results
          |> Enum.flat_map(&normalize_result(&1, module, index))
          |> apply_provider_ranking(provider_opts)

        {:ok, normalized}

      {:error, reason} ->
        {:error, reason}

      _unexpected ->
        {:error, :invalid_response}
    end
  rescue
    _error -> {:error, :provider_error}
  end

  # Per-provider ranking knobs (set alongside the provider in config):
  # `scoring: :rank` replaces heterogeneous native scores (stars, points,
  # page sizes) with Brave-comparable `1000 - rank`; `score_offset` shifts
  # the whole provider up or down the blend; `max_results` caps how many
  # results the provider may contribute.
  defp apply_provider_ranking(results, opts) do
    results
    |> apply_rank_scoring(Keyword.get(opts, :scoring, :raw))
    |> apply_score_offset(Keyword.get(opts, :score_offset, 0))
    |> apply_max_results(Keyword.get(opts, :max_results))
  end

  defp apply_rank_scoring(results, :rank) do
    results
    |> Enum.with_index()
    |> Enum.map(fn {result, rank} -> %{result | score: 1_000 - rank} end)
  end

  defp apply_rank_scoring(results, _scoring), do: results

  defp apply_score_offset(results, offset) when is_number(offset) and offset != 0 do
    Enum.map(results, fn result -> %{result | score: numeric_score(result.score) + offset} end)
  end

  defp apply_score_offset(results, _offset), do: results

  defp apply_max_results(results, max) when is_integer(max) and max > 0,
    do: Enum.take(results, max)

  defp apply_max_results(results, _max), do: results

  defp normalize_result(%Result{} = result, module, provider_index) do
    result
    |> put_default_source(module)
    |> put_provider_index(provider_index)
    |> valid_result()
  end

  defp normalize_result(result, module, provider_index) when is_map(result) do
    %Result{
      title: result_value(result, :title) || "",
      url: result_value(result, :url) || "",
      snippet: result_value(result, :snippet),
      source: result_value(result, :source),
      score: result_value(result, :score) || 0,
      published_at: result_value(result, :published_at),
      metadata: result_value(result, :metadata) || %{}
    }
    |> put_default_source(module)
    |> put_provider_index(provider_index)
    |> valid_result()
  end

  defp normalize_result(_result, _module, _provider_index), do: []

  defp result_value(result, key), do: Map.get(result, key) || Map.get(result, Atom.to_string(key))

  defp put_default_source(%Result{source: source} = result, module) when source in [nil, ""] do
    %{result | source: module |> Module.split() |> List.last()}
  end

  defp put_default_source(%Result{} = result, _module), do: result

  defp put_provider_index(%Result{metadata: metadata} = result, provider_index) do
    %{result | metadata: Map.put(metadata || %{}, :provider_index, provider_index)}
  end

  defp valid_result(%Result{title: title, url: url} = result) do
    if present?(title) and valid_url?(url), do: [result], else: []
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _uri ->
        false
    end
  end

  defp valid_url?(_url), do: false

  defp dedupe_results(results) do
    results
    |> Enum.reduce(%{}, fn result, acc ->
      key = dedupe_key(result)

      Map.update(acc, key, result, &pick_better_result(&1, result))
    end)
    |> Map.values()
  end

  defp dedupe_key(%Result{metadata: %{kind: :images, image_url: image_url}})
       when is_binary(image_url) do
    canonical_url_key(image_url)
  end

  defp dedupe_key(%Result{url: url}), do: canonical_url_key(url)

  defp pick_better_result(existing, candidate) do
    if result_sort_key(candidate) < result_sort_key(existing), do: candidate, else: existing
  end

  defp result_sort_key(%Result{score: score, metadata: metadata}) do
    provider_index = Map.get(metadata || %{}, :provider_index, 0)
    {-numeric_score(score), provider_index}
  end

  defp numeric_score(score) when is_number(score), do: score
  defp numeric_score(_score), do: 0

  defp canonical_url_key(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(host) ->
        scheme = scheme |> to_string() |> String.downcase()
        host = String.downcase(host)
        port = canonical_port(scheme, uri.port)
        path = canonical_path(uri.path)
        query = canonical_query(uri.query)
        "#{scheme}://#{host}#{port}#{path}#{query}"

      _uri ->
        String.downcase(to_string(url))
    end
  end

  defp canonical_port("http", 80), do: ""
  defp canonical_port("https", 443), do: ""
  defp canonical_port(_scheme, nil), do: ""
  defp canonical_port(_scheme, port), do: ":#{port}"

  defp canonical_path(nil), do: "/"
  defp canonical_path(""), do: "/"

  defp canonical_path(path) do
    path = path |> URI.decode() |> String.trim_trailing("/")
    if path == "", do: "/", else: path
  end

  defp canonical_query(nil), do: ""
  defp canonical_query(""), do: ""

  defp canonical_query(query) do
    params =
      query
      |> URI.query_decoder()
      |> Enum.reject(fn {key, _value} -> tracking_param?(key) end)
      |> Enum.sort()

    if params == [], do: "", else: "?" <> URI.encode_query(params)
  end

  defp tracking_param?(key) do
    key = String.downcase(to_string(key))
    String.starts_with?(key, "utm_") or key in ["fbclid", "gclid", "mc_cid", "mc_eid"]
  end
end
