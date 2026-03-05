defmodule ElektrineWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use ElektrineWeb, :controller

  alias ElektrineWeb.API.Response

  # This clause handles errors returned by Ecto's insert/update/delete.
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    if ext_api_request?(conn) do
      errors =
        Ecto.Changeset.traverse_errors(changeset, &ElektrineWeb.CoreComponents.translate_error/1)

      Response.error(
        conn,
        :unprocessable_entity,
        "validation_failed",
        "Validation failed",
        errors
      )
    else
      conn
      |> put_status(:unprocessable_entity)
      |> put_view(json: ElektrineWeb.ChangesetJSON)
      |> render(:error, changeset: changeset)
    end
  end

  # This clause is an example of how to handle resources that cannot be found.
  def call(conn, {:error, :not_found}) do
    if ext_api_request?(conn) do
      Response.error(conn, :not_found, "not_found", "Not Found")
    else
      conn
      |> put_status(:not_found)
      |> put_view(html: ElektrineWeb.ErrorHTML, json: ElektrineWeb.ErrorJSON)
      |> render(:"404")
    end
  end

  # This clause handles unauthorized access
  def call(conn, {:error, :unauthorized}) do
    if ext_api_request?(conn) do
      Response.error(conn, :unauthorized, "unauthorized", "Unauthorized")
    else
      conn
      |> put_status(:unauthorized)
      |> put_view(json: ElektrineWeb.ErrorJSON)
      |> render(:"401")
    end
  end

  # This clause handles forbidden access
  def call(conn, {:error, :forbidden}) do
    if ext_api_request?(conn) do
      Response.error(conn, :forbidden, "forbidden", "Forbidden")
    else
      conn
      |> put_status(:forbidden)
      |> put_view(json: ElektrineWeb.ErrorJSON)
      |> render(:"403")
    end
  end

  # This clause handles bad request errors
  def call(conn, {:error, :bad_request}) do
    if ext_api_request?(conn) do
      Response.error(conn, :bad_request, "bad_request", "Bad Request")
    else
      conn
      |> put_status(:bad_request)
      |> put_view(json: ElektrineWeb.ErrorJSON)
      |> render(:"400")
    end
  end

  defp ext_api_request?(conn) do
    String.starts_with?(conn.request_path, "/api/ext")
  end
end
