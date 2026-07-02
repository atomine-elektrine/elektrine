defmodule ElektrineWeb.API.FollowRequestController do
  @moduledoc """
  Mastodon-compatible follow request API for pending remote followers.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Profiles

  action_fallback ElektrineWeb.FallbackController

  def index(conn, _params) do
    user = conn.assigns[:current_user]

    requests =
      user.id
      |> Profiles.get_pending_follow_requests()
      |> Enum.map(&format_request/1)

    json(conn, requests)
  end

  def authorize(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, request} <- get_request(user.id, id),
         {1, _} <- Profiles.accept_follow_request(request.id) do
      json(conn, format_relationship(request, following: true, requested: false))
    else
      _ -> not_found(conn)
    end
  end

  def reject(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, request} <- get_request(user.id, id),
         {1, _} <- Profiles.reject_follow_request(request.id) do
      json(conn, format_relationship(request, following: false, requested: false))
    else
      _ -> not_found(conn)
    end
  end

  defp get_request(user_id, id) do
    request =
      user_id
      |> Profiles.get_pending_follow_requests()
      |> Enum.find(&(to_string(&1.id) == to_string(id)))

    if request, do: {:ok, request}, else: {:error, :not_found}
  end

  defp format_request(%{remote_actor: actor} = request) do
    %{
      id: to_string(request.id),
      account_id: to_string(actor.id),
      username: actor.username,
      acct: "#{actor.username}@#{actor.domain}",
      display_name: actor.display_name || actor.username,
      avatar: actor.avatar_url,
      requested_at: request.inserted_at
    }
  end

  defp format_relationship(%{remote_actor: actor}, attrs) do
    %{
      id: to_string(actor.id),
      following: Keyword.fetch!(attrs, :following),
      followed_by: true,
      requested: Keyword.fetch!(attrs, :requested),
      blocking: false,
      muting: false
    }
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "follow request not found"})
  end
end
