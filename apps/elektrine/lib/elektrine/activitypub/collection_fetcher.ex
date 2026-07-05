defmodule Elektrine.ActivityPub.CollectionFetcher do
  @moduledoc """
  Fetches and paginates through ActivityPub collections.

  Handles various collection formats:
  - Collection / OrderedCollection
  - CollectionPage / OrderedCollectionPage
  - Paginated collections with `first`, `next` links

  Based on: https://www.w3.org/TR/activitystreams-core/#paging
  """

  alias Elektrine.ActivityPub.RemoteFetch
  require Logger

  @max_collection_items Application.compile_env(
                          :elektrine,
                          [:activitypub, :max_collection_items],
                          100
                        )
  @max_pages Application.compile_env(:elektrine, [:activitypub, :max_collection_pages], 10)

  @type fetch_result :: {:ok, list(map())} | {:partial, list(map())} | {:error, any()}

  @doc """
  Fetches items from an ActivityPub collection.

  Accepts either a URL string or a collection object map.
  Automatically handles pagination up to configured limits.

  ## Options
  - `:max_items` - Maximum items to fetch (default: #{@max_collection_items})
  - `:max_pages` - Maximum pages to traverse (default: #{@max_pages})

  ## Examples

      iex> fetch_collection("https://example.com/users/alice/likes")
      {:ok, [%{"id" => "...", "type" => "Like"}, ...]}

      iex> fetch_collection(%{"type" => "Collection", "items" => [...]})
      {:ok, [...]}
  """
  @spec fetch_collection(String.t() | map(), keyword()) :: fetch_result()
  def fetch_collection(collection, opts \\ [])

  def fetch_collection(url, opts) when is_binary(url) do
    case RemoteFetch.fetch_object(url, fetch_object_opts(opts)) do
      {:ok, page} ->
        collect_from_page(page, opts)

      {:error, reason} ->
        Logger.warning("Could not fetch collection #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def fetch_collection(%{"type" => type} = collection, opts)
      when type in ["Collection", "OrderedCollection", "CollectionPage", "OrderedCollectionPage"] do
    cond do
      collection_page_content?(collection) ->
        collect_from_page(collection, opts)

      count_only_reference?(collection) ->
        fetch_collection(collection["id"], opts)

      true ->
        collect_from_page(collection, opts)
    end
  end

  # Untyped collection references: use embedded content when present, otherwise
  # follow the "id" URL (count-only refs like %{"id" => ..., "totalItems" => 74}).
  def fetch_collection(%{} = collection, opts) do
    cond do
      items_from_page(collection) != [] or is_map(collection["first"]) or
        is_binary(collection["first"]) or is_binary(collection["next"]) ->
        collect_from_page(collection, opts)

      is_binary(collection["id"]) ->
        fetch_collection(collection["id"], opts)

      true ->
        {:ok, []}
    end
  end

  def fetch_collection(nil, _opts), do: {:ok, []}
  def fetch_collection(_, _opts), do: {:error, :invalid_collection}

  @doc """
  Fetches only the count from a collection without fetching items.

  More efficient when you only need the total.
  """
  @spec fetch_collection_count(String.t() | map()) :: {:ok, non_neg_integer()} | {:error, any()}
  def fetch_collection_count(url) when is_binary(url) do
    case RemoteFetch.fetch_object(url) do
      {:ok, collection} ->
        count_collection_items(collection)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def fetch_collection_count(collection) when is_map(collection),
    do: count_collection_items(collection)

  def fetch_collection_count(_), do: {:ok, 0}

  @doc """
  Fetches actor IDs from a likes/shares collection.

  Returns a list of actor AP IDs who performed the interaction.
  """
  @spec fetch_interaction_actors(String.t() | map(), keyword()) ::
          {:ok, list(String.t())} | {:error, any()}
  def fetch_interaction_actors(collection, opts \\ []) do
    case fetch_collection(collection, opts) do
      {:ok, items} ->
        actors = extract_actors(items)
        {:ok, actors}

      {:partial, items} ->
        actors = extract_actors(items)
        {:ok, actors}

      error ->
        error
    end
  end

  # Private functions

  defp count_collection_items(%{"totalItems" => count}) when is_integer(count) do
    {:ok, max(count, 0)}
  end

  defp count_collection_items(%{"totalItems" => count} = collection) when is_binary(count) do
    case parse_count(count) do
      {:ok, parsed_count} ->
        {:ok, parsed_count}

      :error ->
        count_collection_items_without_total(collection)
    end
  end

  defp count_collection_items(%{"items" => items}) when is_list(items), do: {:ok, length(items)}

  defp count_collection_items(%{"orderedItems" => items}) when is_list(items),
    do: {:ok, length(items)}

  defp count_collection_items(collection) when is_map(collection) do
    count_collection_items_without_total(collection)
  end

  defp count_collection_items(_), do: {:ok, 0}

  defp count_collection_items_without_total(collection) do
    case collect_from_page(collection, max_items: 1000) do
      {:ok, items} -> {:ok, length(items)}
      {:partial, items} -> {:ok, length(items)}
      error -> error
    end
  end

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} -> {:ok, max(count, 0)}
      _ -> :error
    end
  end

  defp normalize_count(value) when is_integer(value), do: max(value, 0)

  defp normalize_count(value) when is_binary(value) do
    case parse_count(value) do
      {:ok, count} -> count
      :error -> 0
    end
  end

  defp normalize_count(_), do: 0

  defp collect_from_page(page, opts) do
    max_items = Keyword.get(opts, :max_items, @max_collection_items)
    max_pages = Keyword.get(opts, :max_pages, @max_pages)
    fetch_opts = fetch_object_opts(opts)

    do_collect(page, [], max_items, max_pages, 0, fetch_opts)
  end

  defp do_collect(_page, items, max_items, _max_pages, _page_count, _fetch_opts)
       when length(items) >= max_items do
    {:ok, Enum.take(items, max_items)}
  end

  defp do_collect(_page, items, _max_items, max_pages, page_count, _fetch_opts)
       when page_count >= max_pages do
    if items == [] do
      {:ok, []}
    else
      {:partial, items}
    end
  end

  defp do_collect(page, items, max_items, max_pages, page_count, fetch_opts) do
    current_items = items_from_page(page)
    all_items = items ++ current_items

    cond do
      # Reached item limit
      length(all_items) >= max_items ->
        {:ok, Enum.take(all_items, max_items)}

      # Has next page
      next_ref = get_next_page(page) ->
        follow_page(next_ref, all_items, max_items, max_pages, page_count, fetch_opts)

      # Has first page reference (for Collection pointing to first CollectionPage)
      first_ref = get_first_page(page) ->
        follow_page(first_ref, all_items, max_items, max_pages, page_count, fetch_opts)

      # No more pages
      true ->
        {:ok, all_items}
    end
  end

  # Mastodon embeds the first CollectionPage inline (without an "id"), so
  # embedded page maps are traversed directly instead of re-fetched by URL.
  defp follow_page({:embedded, page}, items, max_items, max_pages, page_count, fetch_opts) do
    do_collect(page, items, max_items, max_pages, page_count + 1, fetch_opts)
  end

  defp follow_page(url, items, max_items, max_pages, page_count, fetch_opts)
       when is_binary(url) do
    case RemoteFetch.fetch_object(url, fetch_opts) do
      {:ok, page} ->
        do_collect(page, items, max_items, max_pages, page_count + 1, fetch_opts)

      {:error, _reason} ->
        # Failed to fetch the page, return what we have
        if items == [] do
          {:error, :fetch_failed}
        else
          {:partial, items}
        end
    end
  end

  defp items_from_page(%{"orderedItems" => items}) when is_list(items), do: items
  defp items_from_page(%{"items" => items}) when is_list(items), do: items
  defp items_from_page(_), do: []

  defp collection_page_content?(collection) do
    items_from_page(collection) != [] or is_map(collection["first"]) or
      is_binary(collection["first"]) or is_binary(collection["next"])
  end

  defp count_only_reference?(%{"id" => id} = collection) when is_binary(id) do
    collection["totalItems"]
    |> normalize_count()
    |> Kernel.>(0)
  end

  defp count_only_reference?(_), do: false

  defp get_next_page(%{"next" => next}) when is_binary(next), do: next
  defp get_next_page(%{"next" => %{} = next}), do: page_ref(next)
  defp get_next_page(_), do: nil

  defp get_first_page(%{"first" => first}) when is_binary(first), do: first
  defp get_first_page(%{"first" => %{} = first}), do: page_ref(first)
  defp get_first_page(_), do: nil

  # An embedded page with content is used as-is; a bare reference like
  # %{"id" => url} still needs to be fetched.
  defp page_ref(%{} = page) do
    if items_from_page(page) != [] or get_next_page(page) != nil do
      {:embedded, page}
    else
      case page["id"] do
        id when is_binary(id) -> id
        _ -> nil
      end
    end
  end

  defp fetch_object_opts(opts) do
    opts
    |> Keyword.take([:request_fun, :skip_cache, :sign, :validate_url, :allow_recovery])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp extract_actors(items) do
    items
    |> Enum.map(&extract_actor/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Like/Announce activity - actor is in "actor" field
  defp extract_actor(%{"actor" => actor}) when is_binary(actor), do: actor
  defp extract_actor(%{"actor" => %{"id" => id}}) when is_binary(id), do: id

  # Direct actor reference (some implementations just list actor IDs)
  defp extract_actor(actor) when is_binary(actor), do: actor

  # Actor object
  defp extract_actor(%{"id" => id, "type" => type})
       when type in ["Person", "Service", "Application", "Group"], do: id

  defp extract_actor(_), do: nil
end
