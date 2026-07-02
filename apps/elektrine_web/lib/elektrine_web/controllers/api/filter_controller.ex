defmodule ElektrineWeb.API.FilterController do
  @moduledoc """
  Mastodon-compatible filter API backed by Elektrine social filters.
  """
  use ElektrineWeb, :controller

  action_fallback ElektrineWeb.FallbackController

  def index(conn, _params) do
    user = conn.assigns[:current_user]

    filters =
      filters().list_filters(user.id)
      |> Enum.map(&format_filter/1)

    json(conn, filters)
  end

  def create(conn, params) do
    user = conn.assigns[:current_user]

    case filters().create_filter(user.id, normalize_params(params)) do
      {:ok, filter} ->
        conn
        |> put_status(:created)
        |> json(format_filter(filter))

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case get_user_filter(id, user.id) do
      nil -> not_found(conn)
      filter -> json(conn, format_filter(filter))
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with filter when not is_nil(filter) <- get_user_filter(id, user.id),
         {:ok, updated} <- filters().update_filter(filter, normalize_params(params)) do
      json(conn, format_filter(updated))
    else
      nil -> not_found(conn)
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case filters().delete_filter(id, user.id) do
      {:ok, _filter} -> json(conn, %{id: to_string(id), deleted: true})
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp get_user_filter(id, user_id) do
    filters().list_filters(user_id)
    |> Enum.find(&(to_string(&1.id) == to_string(id)))
  end

  defp normalize_params(params) do
    %{
      kind: params["kind"] || params["type"] || infer_kind(params),
      value: params["value"] || params["phrase"],
      contexts: List.wrap(params["context"] || params["contexts"]),
      action: params["filter_action"] || params["action"] || "hide",
      whole_word: truthy?(params["whole_word"]),
      expires_at: parse_expires_at(params)
    }
  end

  defp infer_kind(%{"phrase" => _}), do: "keyword"
  defp infer_kind(_), do: "keyword"

  defp parse_expires_at(%{"expires_at" => value}) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp parse_expires_at(%{"expires_in" => value}) do
    case parse_int(value, nil) do
      seconds when is_integer(seconds) and seconds > 0 ->
        DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

      _ ->
        nil
    end
  end

  defp parse_expires_at(_), do: nil

  defp format_filter(filter) do
    %{
      id: to_string(filter.id),
      title: filter.value || filter.kind,
      kind: filter.kind,
      value: filter.value,
      context: filter.contexts || [],
      filter_action: filter.action,
      whole_word: filter.whole_word || false,
      expires_at: filter.expires_at,
      keywords: format_keywords(filter),
      statuses: []
    }
  end

  defp format_keywords(%{kind: "keyword", value: value} = filter) when is_binary(value) do
    [%{id: to_string(filter.id), keyword: value, whole_word: filter.whole_word || false}]
  end

  defp format_keywords(_filter), do: []

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp changeset_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end

  defp filters, do: Module.concat([Elektrine, Social, Filters])
end
