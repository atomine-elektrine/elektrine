defmodule Maid do
  @moduledoc "Meta-search core for Maid."

  alias Maid.Result

  @type provider_spec :: module() | {module(), keyword()}

  @doc "Searches configured providers and returns normalized, deduplicated results."
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {:error, :empty_query}
    else
      providers = Keyword.get(opts, :providers, configured_providers())
      limit = opts |> Keyword.get(:limit, 10) |> normalize_limit()

      provider_results =
        providers
        |> Enum.with_index()
        |> Enum.map(fn {provider, index} -> search_provider(provider, query, index) end)

      results =
        provider_results
        |> Enum.flat_map(fn
          {:ok, results} -> results
          {:error, _reason} -> []
        end)
        |> dedupe_results()
        |> Enum.sort_by(&result_sort_key/1, :asc)
        |> Enum.take(limit)

      if results == [] and provider_results != [] and
           Enum.all?(provider_results, &match?({:error, _reason}, &1)) do
        {:error, :providers_unavailable}
      else
        {:ok, results}
      end
    end
  end

  def search(_query, _opts), do: {:error, :invalid_query}

  defp configured_providers do
    :maid
    |> Application.get_env(:providers, [])
    |> List.wrap()
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(50)
  defp normalize_limit(_limit), do: 10

  defp search_provider({module, provider_opts}, query, index) when is_atom(module) do
    run_provider(module, query, provider_opts, index)
  end

  defp search_provider(module, query, index) when is_atom(module) do
    run_provider(module, query, [], index)
  end

  defp search_provider(_provider, _query, _index), do: {:error, :invalid_provider}

  defp run_provider(module, query, provider_opts, index) do
    case module.search(query, provider_opts) do
      {:ok, results} when is_list(results) ->
        {:ok, Enum.flat_map(results, &normalize_result(&1, module, index))}

      {:error, reason} ->
        {:error, reason}

      _unexpected ->
        {:error, :invalid_response}
    end
  rescue
    _error -> {:error, :provider_error}
  end

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
      key = canonical_url_key(result.url)

      Map.update(acc, key, result, &pick_better_result(&1, result))
    end)
    |> Map.values()
  end

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
        "#{scheme}://#{host}#{port}#{path}"

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
end
