defmodule ElektrineWeb.DiscussionsLive.Settings do
  use ElektrineWeb, :live_view
  alias Elektrine.Messaging

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    user = socket.assigns.current_user

    # Find community by name
    community =
      Elektrine.Repo.get_by(Elektrine.Messaging.Conversation,
        name: name,
        type: "community"
      )

    if community do
      community_id = community.id

      # Check if user is the owner
      is_owner = user && Messaging.is_community_owner?(community_id, user.id)

      if is_owner do
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Elektrine.PubSub, "conversation:#{community_id}")
        end

        # Get community members
        members = Messaging.get_conversation_members(community_id)

        {:ok,
         socket
         |> assign(:page_title, "Settings - #{community.name}")
         |> assign(:community, community)
         |> assign(:members, members)
         |> assign(:is_owner, true)
         |> assign(:active_tab, "general")}
      else
        {:ok,
         socket
         |> notify_error("Only the owner can access community settings")
         |> push_navigate(to: ~p"/discussions/#{name}")}
      end
    else
      {:ok,
       socket
       |> notify_error("Community not found")
       |> push_navigate(to: ~p"/discussions")}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("update_community", params, socket) do
    description = Map.get(params, "description", "")
    rules = Map.get(params, "rules", "")
    category = Map.get(params, "category", "general")
    community = socket.assigns.community

    attrs = %{
      description: description,
      community_rules: rules,
      community_category: category
    }

    case Messaging.update_conversation(community, attrs) do
      {:ok, updated_community} ->
        # Broadcast the community update
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversation:#{updated_community.id}",
          {:community_updated, updated_community}
        )

        {:noreply,
         socket
         |> assign(:community, updated_community)
         |> notify_info("Community settings updated successfully")}

      {:error, changeset} ->
        {:noreply,
         notify_error(socket, "Failed to update settings: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("promote_moderator", %{"user_id" => user_id}, socket) when user_id != "" do
    community_id = socket.assigns.community.id
    user_id = String.to_integer(user_id)

    case Messaging.promote_to_moderator(community_id, user_id) do
      {:ok, _member} ->
        members = Messaging.get_conversation_members(community_id)

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversation:#{community_id}",
          {:member_role_updated, user_id, "moderator"}
        )

        {:noreply,
         socket
         |> assign(:members, members)
         |> notify_info("User promoted to moderator successfully")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to promote user to moderator")}
    end
  end

  def handle_event("promote_moderator", _params, socket) do
    {:noreply, notify_error(socket, "Please select a member to promote")}
  end

  def handle_event("demote_moderator", %{"user_id" => user_id}, socket) do
    community_id = socket.assigns.community.id
    user_id = String.to_integer(user_id)

    case Messaging.demote_from_moderator(community_id, user_id) do
      {:ok, _member} ->
        members = Messaging.get_conversation_members(community_id)

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversation:#{community_id}",
          {:member_role_updated, user_id, "member"}
        )

        {:noreply,
         socket
         |> assign(:members, members)
         |> notify_info("Moderator removed successfully")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to remove moderator")}
    end
  end

  @impl true
  def handle_info({:member_role_updated, _user_id, _new_role}, socket) do
    members = Messaging.get_conversation_members(socket.assigns.community.id)
    {:noreply, assign(socket, :members, members)}
  end

  def handle_info({:new_notification, _notification}, socket) do
    # Simply ignore notifications in the settings page
    # Settings page doesn't need to react to new notifications
    {:noreply, socket}
  end

  def handle_info({:community_updated, updated_community}, socket) do
    {:noreply, assign(socket, :community, updated_community)}
  end
end
