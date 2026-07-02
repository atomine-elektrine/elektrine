defmodule ElektrineWeb.API.ScrobbleController do
  @moduledoc """
  Music listen/scrobble endpoints for compatible social clients.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Repo
  alias Elektrine.Social.Scrobble
  alias Elektrine.Social.Scrobbles
  alias ElektrineWeb.API.AccountJSON

  def create(conn, params) do
    user = conn.assigns[:current_user]

    case Scrobbles.create_scrobble(user, params) do
      {:ok, %Scrobble{} = scrobble} ->
        scrobble = Repo.preload(scrobble, :user)
        json(conn, format_scrobble(scrobble, user))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_scrobble", details: translate_errors(changeset)})
    end
  end

  def index(conn, %{"id" => id} = params) do
    viewer = conn.assigns[:current_user]

    case lookup_user(id) do
      %User{} = user ->
        scrobbles =
          user
          |> Scrobbles.list_public_scrobbles(params)
          |> Enum.map(&format_scrobble(&1, viewer))

        json(conn, scrobbles)

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "account not found"})
    end
  end

  defp lookup_user(id) when is_binary(id) do
    get_user_by_id(id) ||
      Accounts.get_user_by_username_or_handle(String.trim_leading(id, "@"))
  end

  defp lookup_user(_), do: nil

  defp get_user_by_id(id) do
    Repo.get(User, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp format_scrobble(%Scrobble{} = scrobble, viewer) do
    %{
      id: to_string(scrobble.id),
      account: AccountJSON.format_account(scrobble.user, viewer),
      title: scrobble.title,
      artist: scrobble.artist,
      album: scrobble.album,
      length: scrobble.length,
      external_link: scrobble.external_link,
      created_at: scrobble.inserted_at
    }
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
