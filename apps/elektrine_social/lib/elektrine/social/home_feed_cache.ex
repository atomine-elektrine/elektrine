defmodule Elektrine.Social.HomeFeedCache do
  @moduledoc """
  Bounded per-user home feed cache.

  Phoenix-native bounded cache for hot home feed IDs. This keeps the public API
  shaped like a sorted-set feed, but stores IDs in the app cache so callers do
  not need Redis or another external service.
  """

  @cache :app_cache
  @max_items 800
  @ttl :timer.hours(12)

  def put(user_id, post_ids) when is_integer(user_id) and is_list(post_ids) do
    ids = post_ids |> normalize_ids() |> Enum.take(@max_items)
    Cachex.put(@cache, key(user_id), ids, ttl: @ttl)
  end

  def add(user_id, post_id) when is_integer(user_id) and is_integer(post_id) do
    ids =
      user_id
      |> get()
      |> List.wrap()
      |> then(&[post_id | &1])
      |> normalize_ids()
      |> Enum.take(@max_items)

    Cachex.put(@cache, key(user_id), ids, ttl: @ttl)
  end

  def append(user_id, post_ids) when is_integer(user_id) and is_list(post_ids) do
    ids =
      user_id
      |> get()
      |> Kernel.++(normalize_ids(post_ids))
      |> normalize_ids()
      |> Enum.take(@max_items)

    Cachex.put(@cache, key(user_id), ids, ttl: @ttl)
  end

  def delete(user_id, post_id) when is_integer(user_id) and is_integer(post_id) do
    ids = user_id |> get() |> Enum.reject(&(&1 == post_id))
    Cachex.put(@cache, key(user_id), ids, ttl: @ttl)
  end

  def get(user_id) when is_integer(user_id) do
    case Cachex.get(@cache, key(user_id)) do
      {:ok, ids} when is_list(ids) ->
        emit_cache_event(:get, :hit, user_id, length(ids))
        ids

      _ ->
        emit_cache_event(:get, :miss, user_id, 0)
        []
    end
  end

  def clear(user_id) when is_integer(user_id), do: Cachex.del(@cache, key(user_id))

  def clear_all do
    case Cachex.keys(@cache) do
      {:ok, keys} ->
        keys
        |> Enum.filter(&match?({:home_feed, _}, &1))
        |> Enum.each(&Cachex.del(@cache, &1))

        :ok

      _ ->
        :ok
    end
  end

  defp normalize_ids(ids) do
    ids
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
  end

  defp key(user_id), do: {:home_feed, user_id}

  defp emit_cache_event(operation, result, user_id, size) do
    :telemetry.execute(
      [:elektrine, :home_feed, :cache],
      %{count: 1, size: size},
      %{operation: operation, result: result, user_id: user_id}
    )

    :ok
  rescue
    _ -> :ok
  end
end
