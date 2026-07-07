defmodule Elektrine.Social.RecommendationCache do
  @moduledoc """
  Short-lived per-user recommendation ID cache.

  Recommendation ranking is intentionally more expensive than a normal timeline
  query. Cache ranked IDs briefly so hot portal/timeline reloads hydrate a small
  page instead of recomputing every candidate pool.
  """

  @cache :app_cache
  @max_items 200
  @ttl :timer.minutes(10)

  def put(user_id, filter, post_ids)
      when is_integer(user_id) and is_binary(filter) and is_list(post_ids) do
    ids = post_ids |> normalize_ids() |> Enum.take(@max_items)
    Cachex.put(@cache, key(user_id, filter), ids, ttl: @ttl)
  end

  def get(user_id, filter) when is_integer(user_id) and is_binary(filter) do
    case Cachex.get(@cache, key(user_id, filter)) do
      {:ok, ids} when is_list(ids) ->
        emit_cache_event(:get, :hit, user_id, filter, length(ids))
        ids

      _ ->
        emit_cache_event(:get, :miss, user_id, filter, 0)
        []
    end
  end

  def delete(user_id, message_id) when is_integer(user_id) do
    with {:ok, message_id} <- normalize_id(message_id) do
      Enum.each(filters(), fn filter ->
        ids = user_id |> get(filter) |> Enum.reject(&(&1 == message_id))
        Cachex.put(@cache, key(user_id, filter), ids, ttl: @ttl)
      end)
    end

    :ok
  end

  def clear(user_id) when is_integer(user_id) do
    Enum.each(filters(), &Cachex.del(@cache, key(user_id, &1)))
    :ok
  end

  def clear_all do
    case Cachex.keys(@cache) do
      {:ok, keys} ->
        keys
        |> Enum.filter(&match?({:recommendations, _, _}, &1))
        |> Enum.each(&Cachex.del(@cache, &1))

        :ok

      _ ->
        :ok
    end
  end

  defp filters, do: ~w(all timeline gallery discussions)

  defp normalize_ids(ids) do
    ids
    |> Enum.flat_map(fn id ->
      case normalize_id(id) do
        {:ok, id} -> [id]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  defp normalize_id(id) when is_integer(id), do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  defp normalize_id(_id), do: :error

  defp key(user_id, filter), do: {:recommendations, user_id, filter}

  defp emit_cache_event(operation, result, user_id, filter, size) do
    :telemetry.execute(
      [:elektrine, :recommendations, :cache],
      %{count: 1, size: size},
      %{operation: operation, result: result, user_id: user_id, filter: filter}
    )

    :ok
  rescue
    _ -> :ok
  end
end
