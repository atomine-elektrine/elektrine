defmodule ElektrineSocialWeb.RemoteUserLive.FollowOperations do
  @moduledoc """
  Follow/unfollow handling for the remote user profile LiveView.
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [put_flash: 3]

  alias ElektrineSocialWeb.RemoteUserLive.PostState

  def handle_event("toggle_follow", _params, socket) do
    if PostState.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to follow users")}
    else
      remote_actor_id = socket.assigns.remote_actor.id
      current_user_id = socket.assigns.current_user.id
      is_community = socket.assigns.remote_actor.actor_type == "Group"

      if socket.assigns.is_following || socket.assigns.is_pending do
        # Unfollow or cancel pending request
        case Elektrine.Profiles.unfollow_remote_actor(current_user_id, remote_actor_id) do
          {:ok, :unfollowed} ->
            message = if is_community, do: "Left community", else: "Unfollowed"

            {:noreply,
             socket
             |> assign(:is_following, false)
             |> assign(:is_pending, false)
             |> put_flash(:info, message)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:is_following, false)
             |> assign(:is_pending, false)
             |> put_flash(
               :error,
               if(is_community, do: "Failed to leave community", else: "Failed to unfollow")
             )}
        end
      else
        # Follow
        case Elektrine.Profiles.follow_remote_actor(current_user_id, remote_actor_id) do
          {:ok, follow} ->
            # Check if follow is pending (waiting for remote Accept)
            if follow.pending do
              message =
                if is_community,
                  do: "Join request sent! Waiting for approval.",
                  else: "Follow request sent!"

              {:noreply,
               socket
               |> assign(:is_pending, true)
               |> put_flash(:info, message)}
            else
              message = if is_community, do: "Joined community!", else: "Following!"

              {:noreply,
               socket
               |> assign(:is_following, true)
               |> assign(:is_pending, false)
               |> put_flash(:info, message)}
            end

          {:error, :already_following} ->
            {:noreply,
             socket
             |> assign(:is_following, true)
             |> put_flash(
               :info,
               if(is_community, do: "Already a member", else: "Already following")
             )}

          {:error, _reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               if(is_community, do: "Failed to join community", else: "Failed to follow")
             )}
        end
      end
    end
  end

  # Handle follow acceptance - update button state without refresh
  def follow_accepted(socket, remote_actor_id) do
    # Only update if this is the actor we're viewing
    if socket.assigns.remote_actor && socket.assigns.remote_actor.id == remote_actor_id do
      {:noreply,
       socket
       |> assign(:is_following, true)
       |> assign(:is_pending, false)}
    else
      {:noreply, socket}
    end
  end
end
