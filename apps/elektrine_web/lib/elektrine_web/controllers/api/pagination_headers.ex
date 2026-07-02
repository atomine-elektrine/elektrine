defmodule ElektrineWeb.API.PaginationHeaders do
  @moduledoc false

  import Plug.Conn

  @page_param_keys MapSet.new(["max_id", "since_id", "min_id"])

  def put_pagination_links(conn, entries, params \\ %{})

  def put_pagination_links(conn, [], _params), do: conn

  def put_pagination_links(conn, entries, params) when is_list(entries) do
    first_id = entries |> List.first() |> entry_id()
    last_id = entries |> List.last() |> entry_id()

    if first_id && last_id do
      next_url = page_url(conn, params, "max_id", last_id)
      prev_url = page_url(conn, params, "since_id", first_id)

      put_resp_header(conn, "link", "<#{next_url}>; rel=\"next\", <#{prev_url}>; rel=\"prev\"")
    else
      conn
    end
  end

  defp page_url(conn, params, page_key, page_id) do
    query =
      params
      |> normalize_params()
      |> Map.reject(fn {key, value} -> MapSet.member?(@page_param_keys, key) || blank?(value) end)
      |> Map.put(page_key, to_string(page_id))
      |> URI.encode_query()

    path = conn.request_path || "/"

    if query == "" do
      path
    else
      path <> "?" <> query
    end
  end

  defp normalize_params(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_params(_params), do: %{}

  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value) when is_integer(value), do: to_string(value)
  defp normalize_value(value) when is_boolean(value), do: to_string(value)
  defp normalize_value(_value), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp entry_id(%{id: id}), do: id
  defp entry_id(_entry), do: nil
end
