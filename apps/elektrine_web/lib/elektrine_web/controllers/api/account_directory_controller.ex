defmodule ElektrineWeb.API.AccountDirectoryController do
  @moduledoc """
  Public account directory endpoint for compatible social clients.
  """

  use ElektrineWeb, :controller

  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo
  alias ElektrineWeb.API.AccountJSON

  @default_limit 20
  @max_limit 80
  @max_fetch 500

  def index(conn, params) do
    limit = parse_limit(params["limit"])
    offset = parse_offset(params["offset"])
    local_only? = truthy?(params["local"])
    order = normalize_order(params["order"])
    fetch_limit = min(offset + limit, @max_fetch)

    accounts =
      params
      |> list_directory_accounts(local_only?, order, fetch_limit)
      |> sort_accounts(order)
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> AccountJSON.format_accounts(conn.assigns[:current_user])

    json(conn, accounts)
  end

  defp list_directory_accounts(_params, true, _order, fetch_limit) do
    list_local_accounts(fetch_limit)
  end

  defp list_directory_accounts(_params, false, _order, fetch_limit) do
    list_local_accounts(fetch_limit) ++ list_remote_actors(fetch_limit)
  end

  defp list_local_accounts(limit) do
    from(user in User,
      where: user.banned != true,
      where: user.suspended != true,
      where: user.profile_visibility == "public",
      order_by: [
        desc:
          fragment(
            "COALESCE(?, ?, ?)",
            user.last_seen_at,
            user.status_updated_at,
            user.inserted_at
          )
      ],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp list_remote_actors(limit) do
    from(actor in Actor,
      where: actor.actor_type in ["Person", "Group", "Organization", "Service", "Application"],
      order_by: [
        desc:
          fragment(
            "COALESCE(?, ?, ?)",
            actor.last_fetched_at,
            actor.published_at,
            actor.inserted_at
          )
      ],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp sort_accounts(accounts, "new") do
    Enum.sort_by(accounts, &sort_unix(&1, :created), :desc)
  end

  defp sort_accounts(accounts, _order) do
    Enum.sort_by(accounts, &sort_unix(&1, :active), :desc)
  end

  defp sort_unix(account, type), do: account |> sort_datetime(type) |> datetime_to_unix()

  defp sort_datetime(%User{} = user, :active) do
    user.last_seen_at || user.status_updated_at || user.inserted_at || epoch()
  end

  defp sort_datetime(%Actor{} = actor, :active) do
    actor.last_fetched_at || actor.published_at || actor.inserted_at || epoch()
  end

  defp sort_datetime(%User{} = user, :created), do: user.inserted_at || epoch()

  defp sort_datetime(%Actor{} = actor, :created),
    do: actor.inserted_at || actor.published_at || epoch()

  defp parse_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> parse_limit(limit)
      _ -> @default_limit
    end
  end

  defp parse_limit(_value), do: @default_limit

  defp parse_offset(value) when is_integer(value), do: max(value, 0)

  defp parse_offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} -> parse_offset(offset)
      _ -> 0
    end
  end

  defp parse_offset(_value), do: 0

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_value), do: false

  defp normalize_order("new"), do: "new"
  defp normalize_order(_order), do: "active"

  defp epoch, do: ~U[1970-01-01 00:00:00Z]

  defp datetime_to_unix(%DateTime{} = datetime), do: DateTime.to_unix(datetime)

  defp datetime_to_unix(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix()
  end

  defp datetime_to_unix(_datetime), do: 0
end
