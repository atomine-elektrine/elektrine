defmodule ElektrineWeb.MastodonAPI.FallbackController do
  @moduledoc """
  Fallback controller for Mastodon API errors.

  Translates common errors into Mastodon API-compatible JSON responses.
  """

  use Phoenix.Controller, formats: [:json]

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: ElektrineWeb.MastodonAPI.ErrorView)
    |> render(:error, error: "Record not found")
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: ElektrineWeb.MastodonAPI.ErrorView)
    |> render(:error, error: "The access token is invalid")
  end

  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: ElektrineWeb.MastodonAPI.ErrorView)
    |> render(:error, error: "This action is not allowed")
  end

  def call(conn, {:error, :insufficient_scope}) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: ElektrineWeb.MastodonAPI.ErrorView)
    |> render(:error, error: "This action is outside the authorized scopes")
  end

  def call(conn, {:error, :rate_limited}) do
    conn
    |> put_status(:too_many_requests)
    |> put_view(json: ElektrineWeb.MastodonAPI.ErrorView)
    |> render(:error, error: "Rate limit exceeded")
  end

  def call(conn, {:error, :unprocessable_entity, message}) when is_binary(message) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ElektrineWeb.MastodonAPI.ErrorView)
    |> render(:error, error: message)
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ElektrineWeb.MastodonAPI.ErrorView)
    |> render(:changeset_error, changeset: changeset)
  end

  def call(conn, {:error, message}) when is_binary(message) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ElektrineWeb.MastodonAPI.ErrorView)
    |> render(:error, error: message)
  end

  def call(conn, nil) do
    conn
    |> put_status(:not_found)
    |> put_view(json: ElektrineWeb.MastodonAPI.ErrorView)
    |> render(:error, error: "Record not found")
  end
end
