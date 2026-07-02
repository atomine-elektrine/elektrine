defmodule ElektrineWeb.API.AccountStatusController do
  @moduledoc """
  API endpoint for listing profile statuses.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias ElektrineWeb.API.StatusJSON

  action_fallback ElektrineWeb.FallbackController

  @default_limit 20
  @max_limit 80

  def index(conn, %{"id" => id} = params) do
    viewer = conn.assigns[:current_user]

    case Repo.get(Accounts.User, id) do
      %User{} = account ->
        statuses =
          social().get_account_statuses(account.id, opts(params, viewer.id))
          |> Enum.map(&Message.decrypt_content/1)

        json(conn, StatusJSON.format_statuses(statuses, viewer.id))

      nil ->
        not_found(conn)
    end
  rescue
    Ecto.Query.CastError -> not_found(conn)
  end

  def favourites(conn, %{"id" => id} = params) do
    viewer = conn.assigns[:current_user]

    case Repo.get(Accounts.User, id) do
      %User{} = account ->
        statuses =
          if account.hide_favorites == true and account.id != viewer.id do
            []
          else
            social().get_liked_posts(account.id, liked_opts(params, viewer.id))
            |> Enum.map(&Message.decrypt_content/1)
          end

        json(conn, StatusJSON.format_statuses(statuses, viewer.id))

      nil ->
        not_found(conn)
    end
  rescue
    Ecto.Query.CastError -> not_found(conn)
  end

  defp opts(params, viewer_id) do
    [
      viewer_id: viewer_id,
      limit: parse_limit(params["limit"]),
      before_id: params["max_id"],
      since_id: params["since_id"],
      min_id: params["min_id"],
      pinned: truthy?(params["pinned"]),
      only_media: truthy?(params["only_media"]),
      exclude_reblogs: truthy?(params["exclude_reblogs"]),
      only_reblogs: truthy?(params["only_reblogs"]),
      exclude_replies: truthy?(params["exclude_replies"])
    ]
  end

  defp liked_opts(params, viewer_id) do
    [
      viewer_id: viewer_id,
      limit: parse_limit(params["limit"]),
      before_id: positive_id(params["max_id"]),
      since_id: positive_id(params["since_id"]),
      min_id: positive_id(params["min_id"]),
      search_query: text_param(params["q"]) || text_param(params["search"])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp parse_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> parse_limit(limit)
      _ -> @default_limit
    end
  end

  defp parse_limit(_value), do: @default_limit

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_value), do: false

  defp positive_id(value) when is_integer(value) and value > 0, do: value

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp positive_id(_value), do: nil

  defp text_param(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp text_param(_value), do: nil

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "account not found"})
  end

  defp social, do: Module.concat([Elektrine, Social])
end
