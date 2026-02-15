defmodule ElektrineWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use ElektrineWeb, :controller

  # This clause handles errors returned by Ecto's insert/update/delete.
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ElektrineWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  # This clause is an example of how to handle resources that cannot be found.
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(html: ElektrineWeb.ErrorHTML, json: ElektrineWeb.ErrorJSON)
    |> render(:"404")
  end

  # This clause handles unauthorized access
  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: ElektrineWeb.ErrorJSON)
    |> render(:"401")
  end

  # This clause handles forbidden access
  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: ElektrineWeb.ErrorJSON)
    |> render(:"403")
  end

  # This clause handles bad request errors
  def call(conn, {:error, :bad_request}) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: ElektrineWeb.ErrorJSON)
    |> render(:"400")
  end
end
