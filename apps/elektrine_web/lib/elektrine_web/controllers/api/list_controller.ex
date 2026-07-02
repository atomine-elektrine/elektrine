defmodule ElektrineWeb.API.ListController do
  @moduledoc """
  API endpoints for user-managed account lists.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor
  alias ElektrineWeb.API.{AccountJSON, PaginationHeaders, StatusJSON}

  action_fallback ElektrineWeb.FallbackController

  def index(conn, _params) do
    user = conn.assigns[:current_user]

    lists =
      user.id
      |> social().list_user_lists()
      |> Enum.map(&format_list/1)

    json(conn, lists)
  end

  def create(conn, params) do
    user = conn.assigns[:current_user]

    attrs =
      params
      |> list_attrs()
      |> Map.put(:user_id, user.id)

    case social().create_list(attrs) do
      {:ok, list} -> json(conn, format_list(list))
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, list_id} <- parse_id(id),
         list when not is_nil(list) <- social().get_user_list(user.id, list_id) do
      json(conn, format_list(list))
    else
      _ -> not_found(conn)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, list_id} <- parse_id(id),
         list when not is_nil(list) <- social().get_user_list(user.id, list_id),
         {:ok, updated} <- social().update_list(list, list_attrs(params)) do
      json(conn, format_list(updated))
    else
      {:error, %Ecto.Changeset{} = changeset} -> changeset_error(conn, changeset)
      _ -> not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, list_id} <- parse_id(id),
         list when not is_nil(list) <- social().get_user_list(user.id, list_id),
         {:ok, _deleted} <- social().delete_list(list) do
      json(conn, %{})
    else
      _ -> not_found(conn)
    end
  end

  def accounts(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, list_id} <- parse_id(id),
         list when not is_nil(list) <- social().get_user_list(user.id, list_id) do
      accounts =
        list.list_members
        |> Enum.map(&member_account/1)
        |> Enum.reject(&is_nil/1)
        |> AccountJSON.format_accounts(user)

      json(conn, accounts)
    else
      _ -> not_found(conn)
    end
  end

  def add_accounts(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, list_id} <- parse_id(id),
         {:ok, _members} <- social().add_accounts_to_list(user.id, list_id, params),
         list when not is_nil(list) <- social().get_user_list(user.id, list_id) do
      json(conn, format_list(list))
    else
      {:error, %Ecto.Changeset{} = changeset} -> changeset_error(conn, changeset)
      _ -> not_found(conn)
    end
  end

  def remove_accounts(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, list_id} <- parse_id(id),
         {:ok, :removed} <-
           social().remove_accounts_from_list(user.id, list_id, params),
         list when not is_nil(list) <- social().get_user_list(user.id, list_id) do
      json(conn, format_list(list))
    else
      _ -> not_found(conn)
    end
  end

  def timeline(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, list_id} <- parse_id(id),
         list when not is_nil(list) <- social().get_user_list(user.id, list_id) do
      posts = social().get_list_timeline(list.id, timeline_opts(params, user.id))

      conn
      |> PaginationHeaders.put_pagination_links(posts, Map.delete(params, "id"))
      |> json(StatusJSON.format_statuses(posts, user.id))
    else
      _ -> not_found(conn)
    end
  end

  defp list_attrs(params) do
    %{}
    |> maybe_put_list_attr(:name, params["title"] || params["name"])
    |> maybe_put_list_attr(:description, params["description"])
    |> maybe_put_list_attr(:visibility, params["visibility"])
  end

  defp maybe_put_list_attr(attrs, _key, nil), do: attrs
  defp maybe_put_list_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp format_list(list) do
    %{
      id: to_string(list.id),
      title: list.name,
      replies_policy: "list",
      exclusive: false,
      description: list.description,
      visibility: list.visibility,
      accounts_count: list_member_count(list),
      pleroma: %{
        emoji: nil,
        emoji_url: nil
      }
    }
  end

  defp list_member_count(%{list_members: %Ecto.Association.NotLoaded{}}), do: 0
  defp list_member_count(%{list_members: members}) when is_list(members), do: length(members)
  defp list_member_count(_list), do: 0

  defp member_account(%{user: %User{} = user}), do: user
  defp member_account(%{remote_actor: %Actor{} = actor}), do: actor
  defp member_account(_member), do: nil

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_id(_value), do: {:error, :invalid_id}

  defp timeline_opts(params, user_id) do
    [
      viewer_id: user_id,
      limit: parse_limit(params["limit"]),
      before_id: positive_id(params["max_id"]),
      since_id: positive_id(params["since_id"]),
      min_id: positive_id(params["min_id"])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp parse_limit(nil), do: 20

  defp parse_limit(value) do
    value
    |> positive_id()
    |> case do
      nil -> 20
      limit -> limit |> max(1) |> min(40)
    end
  end

  defp positive_id(value) when is_integer(value) and value > 0, do: value

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp positive_id(_value), do: nil

  defp changeset_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "list not found"})
  end

  defp social, do: Module.concat([Elektrine, Social])
end
