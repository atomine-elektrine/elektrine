defmodule Elektrine.ActivityPub.CollectionFetcher do
  @moduledoc """
  Fetches and paginates through ActivityPub collections.

  Handles various collection formats:
  - Collection / OrderedCollection
  - CollectionPage / OrderedCollectionPage
  - Paginated collections with `first`, `next` links

  Based on: https://www.w3.org/TR/activitystreams-core/#paging
  """

  alias Elektrine.ActivityPub.Fetcher
  require Logger

  @max_collection_items Application.compile_env(
                          :elektrine,
                          [:activitypub, :max_collection_items],
                          100
                        )
  @max_pages Application.compile_env(:elektrine, [:activitypub, :max_collection_pages], 5)

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
    case Fetcher.fetch_object(url) do
      {:ok, page} ->
        collect_from_page(page, opts)

      {:error, reason} ->
        Logger.warning("Could not fetch collection #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def fetch_collection(%{"type" => type} = collection, opts)
      when type in ["Collection", "OrderedCollection", "CollectionPage", "OrderedCollectionPage"] do
    collect_from_page(collection, opts)
  end

  def fetch_collection(%{"totalItems" => count}, _opts) when is_integer(count) do
    # Collection reference with only count, no items to fetch
    {:ok, []}
  end

  def fetch_collection(nil, _opts), do: {:ok, []}
  def fetch_collection(_, _opts), do: {:error, :invalid_collection}

  @doc """
  Fetches only the count from a collection without fetching items.

  More efficient when you only need the total.
  """
  @spec fetch_collection_count(String.t() | map()) :: {:ok, non_neg_integer()} | {:error, any()}
  def fetch_collection_count(url) when is_binary(url) do
    case Fetcher.fetch_object(url) do
      {:ok, %{"totalItems" => count}} when is_integer(count) ->
        {:ok, count}

      {:ok, %{"totalItems" => count}} when is_binary(count) ->
        {:ok, String.to_integer(count)}

      {:ok, collection} ->
        # No totalItems, need to count items
        case collect_from_page(collection, max_items: 1000) do
          {:ok, items} -> {:ok, length(items)}
          {:partial, items} -> {:ok, length(items)}
          error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def fetch_collection_count(%{"totalItems" => count}) when is_integer(count), do: {:ok, count}

  def fetch_collection_count(%{"totalItems" => count}) when is_binary(count),
    do: {:ok, String.to_integer(count)}

  def fetch_collection_count(%{"items" => items}) when is_list(items), do: {:ok, length(items)}

  def fetch_collection_count(%{"orderedItems" => items}) when is_list(items),
    do: {:ok, length(items)}

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

  defp collect_from_page(page, opts) do
    max_items = Keyword.get(opts, :max_items, @max_collection_items)
    max_pages = Keyword.get(opts, :max_pages, @max_pages)

    do_collect(page, [], max_items, max_pages, 0)
  end

  defp do_collect(_page, items, max_items, _max_pages, _page_count)
       when length(items) >= max_items do
    {:ok, Enum.take(items, max_items)}
  end

  defp do_collect(_page, items, _max_items, max_pages, page_count) when page_count >= max_pages do
    if items == [] do
      {:ok, []}
    else
      {:partial, items}
    end
  end

  defp do_collect(page, items, max_items, max_pages, page_count) do
    current_items = items_from_page(page)
    all_items = items ++ current_items

    cond do
      # Reached item limit
      length(all_items) >= max_items ->
        {:ok, Enum.take(all_items, max_items)}

      # Has next page
      next_url = get_next_page(page) ->
        case Fetcher.fetch_object(next_url) do
          {:ok, next_page} ->
            do_collect(next_page, all_items, max_items, max_pages, page_count + 1)

          {:error, _reason} ->
            # Failed to fetch next page, return what we have
            if all_items == [] do
              {:error, :fetch_failed}
            else
              {:partial, all_items}
            end
        end

      # Has first page reference (for Collection pointing to first CollectionPage)
      first_url = get_first_page(page) ->
        case Fetcher.fetch_object(first_url) do
          {:ok, first_page} ->
            do_collect(first_page, all_items, max_items, max_pages, page_count + 1)

          {:error, _reason} ->
            if all_items == [] do
              {:error, :fetch_failed}
            else
              {:partial, all_items}
            end
        end

      # No more pages
      true ->
        {:ok, all_items}
    end
  end

  defp items_from_page(%{"orderedItems" => items}) when is_list(items), do: items
  defp items_from_page(%{"items" => items}) when is_list(items), do: items
  defp items_from_page(_), do: []

  defp get_next_page(%{"next" => next}) when is_binary(next), do: next
  defp get_next_page(%{"next" => %{"id" => id}}) when is_binary(id), do: id
  defp get_next_page(_), do: nil

  defp get_first_page(%{"first" => first}) when is_binary(first), do: first
  defp get_first_page(%{"first" => %{"id" => id}}) when is_binary(id), do: id
  defp get_first_page(_), do: nil

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
