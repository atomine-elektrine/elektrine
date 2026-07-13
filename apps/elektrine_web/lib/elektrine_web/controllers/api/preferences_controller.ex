defmodule ElektrineWeb.API.PreferencesController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts

  @doc """
  Persists the site theme mode picked with the navbar day/night toggle so it
  follows the user across devices.
  """
  def update_theme(conn, %{"mode" => mode}) do
    case Accounts.update_user(conn.assigns.current_user, %{"theme_mode" => mode}) do
      {:ok, user} ->
        json(conn, %{theme_mode: user.theme_mode})

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "is not a supported theme mode"})
    end
  end

  def update_theme(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing theme mode"})
  end
end
