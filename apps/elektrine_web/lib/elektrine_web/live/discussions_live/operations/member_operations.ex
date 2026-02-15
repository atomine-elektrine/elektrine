defmodule ElektrineWeb.DiscussionsLive.Operations.MemberOperations do
  @moduledoc """
  Handles all member-related operations: joining, leaving, searching members, following.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  # Import verified routes for ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.{Messaging, Profiles}

  # Join community
  def handle_event("join_community", _params, socket) do
    if socket.assigns.current_user do
      community = socket.assigns.community
      user_id = socket.assigns.current_user.id

      case Messaging.add_member_to_conversation(community.id, user_id, "member") do
        {:ok, _member} ->
          # Update member list and status
          members = Messaging.get_conversation_members(community.id)
          filtered_members = members

          {:noreply,
           socket
           |> assign(:is_member, true)
           |> assign(:members, members)
           |> assign(:filtered_members, filtered_members)
           |> notify_info("You're now following !#{community.name}. Welcome in.")}

        {:error, :privacy_restriction} ->
          {:noreply, notify_error(socket, "Cannot join due to privacy settings")}

        _ ->
          {:noreply,
           notify_error(socket, "Couldn't join this community right now. Please try again.")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to join")}
    end
  end

  # Leave community
  def handle_event("leave_community", _params, socket) do
    if socket.assigns.current_user do
      community = socket.assigns.community
      user_id = socket.assigns.current_user.id

      case Messaging.remove_member_from_conversation(community.id, user_id) do
        {:ok, _} ->
          # Update member list and status
          members = Messaging.get_conversation_members(community.id)
          filtered_members = members

          {:noreply,
           socket
           |> assign(:is_member, false)
           |> assign(:members, members)
           |> assign(:filtered_members, filtered_members)
           |> notify_info("You left this community. You can rejoin anytime.")}

        _ ->
          {:noreply,
           notify_error(socket, "Couldn't leave this community right now. Please try again.")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to leave")}
    end
  end

  # Search members
  def handle_event("search_members", %{"value" => search_term}, socket) do
    filtered_members =
      if search_term == "" do
        socket.assigns.members
      else
        search = String.downcase(search_term)

        Enum.filter(socket.assigns.members, fn member ->
          username = Map.get(member, :username, "")
          # Members might not have display_name in the map
          String.contains?(String.downcase(username), search)
        end)
      end

    {:noreply,
     socket
     |> assign(:member_search, search_term)
     |> assign(:filtered_members, filtered_members)}
  end

  # Toggle follow/unfollow user
  def handle_event("toggle_follow", %{"user_id" => user_id}, socket) do
    if socket.assigns.current_user do
      target_user_id = String.to_integer(user_id)
      current_user_id = socket.assigns.current_user.id

      # Check if currently following (we need to track this in assigns)
      currently_following = Map.get(socket.assigns[:user_follows] || %{}, target_user_id, false)

      if currently_following do
        # Unfollow
        case Profiles.unfollow_user(current_user_id, target_user_id) do
          {1, _} ->
            {:noreply,
             socket
             |> update_user_follow_status(target_user_id, false)
             |> put_flash(:info, "Unfollowed user.")}

          _ ->
            {:noreply, notify_error(socket, "Couldn't unfollow right now. Please try again.")}
        end
      else
        # Follow
        case Profiles.follow_user(current_user_id, target_user_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> update_user_follow_status(target_user_id, true)
             |> put_flash(:info, "Now following user.")}

          {:error, _} ->
            {:noreply, notify_error(socket, "Couldn't follow right now. Please try again.")}
        end
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to follow users")}
    end
  end

  # Private helpers

  defp update_user_follow_status(socket, user_id, is_following) do
    update(socket, :user_follows, fn follows ->
      Map.put(follows || %{}, user_id, is_following)
    end)
  end

  defp notify_error(socket, message) do
    put_flash(socket, :error, message)
  end

  defp notify_info(socket, message) do
    put_flash(socket, :info, message)
  end
end
