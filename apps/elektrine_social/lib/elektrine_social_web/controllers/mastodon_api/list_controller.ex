defmodule ElektrineSocialWeb.MastodonAPI.ListController do
  @moduledoc """
  Mastodon-compatible list endpoints backed by Elektrine social lists.
  """

  use ElektrineSocialWeb, :controller

  alias Elektrine.Social.Lists
  alias ElektrineSocialWeb.MastodonAPI.StatusView

  action_fallback(ElektrineSocialWeb.MastodonAPI.FallbackController)

  def index(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def index(%{assigns: %{user: user}} = conn, _params) do
    json(conn, Enum.map(Lists.list_user_lists(user.id), &render_list/1))
  end

  def show(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def show(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, list} <- fetch_list(user.id, id) do
      json(conn, render_list(list))
    end
  end

  def create(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def create(%{assigns: %{user: user}} = conn, params) do
    with {:ok, list} <-
           Lists.create_list(%{user_id: user.id, name: params["title"], visibility: "private"}) do
      json(conn, render_list(list))
    end
  end

  def update(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def update(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, list} <- fetch_list(user.id, id),
         {:ok, updated} <- Lists.update_list(list, %{name: params["title"] || list.name}) do
      json(conn, render_list(updated))
    end
  end

  def delete(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def delete(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, list} <- fetch_list(user.id, id),
         {:ok, _} <- Lists.delete_list(list) do
      json(conn, %{})
    end
  end

  def accounts(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def accounts(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, list} <- fetch_list(user.id, id) do
      accounts =
        list.list_members
        |> Enum.map(fn member -> member.user && StatusView.render_account(member.user, user) end)
        |> Enum.reject(&is_nil/1)

      json(conn, accounts)
    end
  end

  def add_accounts(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def add_accounts(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, list} <- fetch_list(user.id, id) do
      Enum.each(account_ids(params), fn account_id ->
        _ = Lists.add_to_list(list.id, %{user_id: account_id})
      end)

      json(conn, %{})
    end
  end

  def remove_accounts(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def remove_accounts(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, list} <- fetch_list(user.id, id) do
      ids = MapSet.new(account_ids(params))

      Enum.each(list.list_members, fn member ->
        if member.user_id in ids do
          _ = Lists.remove_from_list(member.id)
        end
      end)

      json(conn, %{})
    end
  end

  def timeline(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def timeline(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, list} <- fetch_list(user.id, id) do
      posts =
        Lists.get_list_timeline(list.id,
          limit: parse_limit(params["limit"], 20),
          before_id: parse_int(params["max_id"])
        )

      json(conn, StatusView.render_statuses(posts, user))
    end
  end

  defp fetch_list(user_id, id) do
    case parse_int(id) do
      nil ->
        {:error, :not_found}

      list_id ->
        case Lists.get_user_list(user_id, list_id) do
          nil -> {:error, :not_found}
          list -> {:ok, list}
        end
    end
  end

  defp render_list(list) do
    %{id: to_string(list.id), title: list.name, replies_policy: "list", exclusive: false}
  end

  defp account_ids(params) do
    case Map.get(params, "account_ids") || Map.get(params, "account_ids[]") do
      ids when is_list(ids) -> Enum.map(ids, &parse_int/1) |> Enum.reject(&is_nil/1)
      id when is_binary(id) -> [parse_int(id)] |> Enum.reject(&is_nil/1)
      _ -> []
    end
  end

  defp parse_limit(nil, default), do: default

  defp parse_limit(value, default) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> min(max(int, 1), 40)
      _ -> default
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end
end
