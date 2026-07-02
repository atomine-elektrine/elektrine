defmodule ElektrineWeb.API.DomainBlockController do
  @moduledoc """
  JSON API for per-user remote domain blocks.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Accounts

  def index(conn, _params) do
    user = conn.assigns[:current_user]
    json(conn, Accounts.list_blocked_domains(user.id))
  end

  def create(conn, params) do
    user = conn.assigns[:current_user]

    case Accounts.block_domain(user.id, params["domain"]) do
      {:ok, _block} ->
        json(conn, %{})

      {:error, :invalid_domain} ->
        invalid_domain(conn)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
    end
  end

  def delete(conn, params) do
    user = conn.assigns[:current_user]

    case Accounts.unblock_domain(user.id, params["domain"]) do
      {:ok, _result} ->
        json(conn, %{})

      {:error, :invalid_domain} ->
        invalid_domain(conn)
    end
  end

  defp invalid_domain(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid domain"})
  end
end
