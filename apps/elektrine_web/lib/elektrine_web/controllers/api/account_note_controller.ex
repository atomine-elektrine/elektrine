defmodule ElektrineWeb.API.AccountNoteController do
  @moduledoc """
  Mastodon-compatible account note endpoint.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo
  alias ElektrineWeb.API.AccountJSON

  action_fallback ElektrineWeb.FallbackController

  def create(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, target, account} <- resolve_account(id),
         {:ok, note} <- Accounts.put_account_note(user.id, target, params["comment"] || "") do
      json(
        conn,
        account |> AccountJSON.format_account(user) |> Map.put(:note, note.comment || "")
      )
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "account not found"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
    end
  end

  defp resolve_account(id) do
    case Repo.get(Elektrine.Accounts.User, id) do
      %Elektrine.Accounts.User{} = user ->
        {:ok, {:user, user.id}, user}

      nil ->
        case Repo.get(Actor, id) do
          %Actor{} = actor -> {:ok, {:remote_actor, actor.id}, actor}
          nil -> {:error, :not_found}
        end
    end
  end
end
