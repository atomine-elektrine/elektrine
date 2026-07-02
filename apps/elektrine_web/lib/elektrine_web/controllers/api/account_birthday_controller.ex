defmodule ElektrineWeb.API.AccountBirthdayController do
  @moduledoc """
  Birthday reminder endpoints for compatible social clients.
  """

  use ElektrineWeb, :controller

  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  @max_limit 80

  def index(conn, params) do
    with {:ok, day} <- parse_range(params["day"], 1, 31),
         {:ok, month} <- parse_range(params["month"], 1, 12) do
      viewer = conn.assigns[:current_user]

      accounts =
        viewer.id
        |> visible_followed_birthdays(day, month, parse_limit(params["limit"]))
        |> Enum.map(&account_json/1)

      json(conn, accounts)
    else
      {:error, field} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_#{field}"})
    end
  end

  defp visible_followed_birthdays(viewer_id, day, month, limit) do
    from(user in User,
      join: follow in Follow,
      on:
        follow.followed_id == user.id and follow.follower_id == ^viewer_id and
          follow.pending == false,
      where: user.show_birthday == true,
      where: not is_nil(user.birthday),
      where: user.banned != true and user.suspended != true,
      where: fragment("date_part('day', ?)::int", user.birthday) == ^day,
      where: fragment("date_part('month', ?)::int", user.birthday) == ^month,
      order_by: [asc: user.username],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp account_json(%User{} = user) do
    acct = user.handle || user.username

    %{
      id: to_string(user.id),
      username: user.username,
      acct: acct,
      display_name: user.display_name || user.username,
      note: "",
      url: Elektrine.Domains.profile_url_for_user(user) || "/#{acct}",
      avatar: user.avatar,
      avatar_static: user.avatar,
      header: nil,
      header_static: nil,
      locked: user.activitypub_manually_approve_followers || false,
      bot: false,
      discoverable: user.profile_visibility != "private",
      created_at: user.inserted_at,
      remote: false,
      pleroma: %{
        birthday: user.birthday
      }
    }
  end

  defp parse_range(value, min, max) do
    case parse_integer(value) do
      int when is_integer(int) and int >= min and int <= max -> {:ok, int}
      _ -> {:error, if(max == 31, do: :day, else: :month)}
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp parse_limit(value) do
    value
    |> parse_integer()
    |> case do
      int when is_integer(int) -> int |> max(1) |> min(@max_limit)
      _ -> @max_limit
    end
  end
end
