defmodule ElektrineWeb.API.OutgoingFollowRequestController do
  @moduledoc """
  Pleroma-compatible outgoing follow request API.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Profiles

  action_fallback ElektrineWeb.FallbackController

  def index(conn, _params) do
    user = conn.assigns[:current_user]

    requests =
      user.id
      |> Profiles.get_pending_outgoing_follow_requests()
      |> Enum.map(&format_request/1)

    json(conn, requests)
  end

  def cancel(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with request when not is_nil(request) <- find_request(user.id, id),
         {:ok, :unfollowed} <- Profiles.unfollow_remote_actor(user.id, request.remote_actor.id) do
      json(conn, %{id: to_string(request.remote_actor.id), requested: false})
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "outgoing follow request not found"})
    end
  end

  defp find_request(user_id, id) do
    user_id
    |> Profiles.get_pending_outgoing_follow_requests()
    |> Enum.find(fn request ->
      to_string(request.id) == to_string(id) ||
        to_string(request.remote_actor.id) == to_string(id)
    end)
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
end
