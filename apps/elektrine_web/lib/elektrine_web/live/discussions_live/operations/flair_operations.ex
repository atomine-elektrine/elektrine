defmodule ElektrineWeb.DiscussionsLive.Operations.FlairOperations do
  @moduledoc """
  Handles all flair management operations: creating, editing, deleting flairs.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  # Import verified routes for ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.Messaging

  @doc "Show new flair modal"
  def handle_event("new_flair", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_flair_modal, true)
     |> assign(:editing_flair, nil)}
  end

  def handle_event("edit_flair", %{"flair_id" => flair_id}, socket) do
    flair = Messaging.get_community_flair!(flair_id)

    {:noreply,
     socket
     |> assign(:show_flair_modal, true)
     |> assign(:editing_flair, flair)}
  end

  def handle_event("cancel_flair", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_flair_modal, false)
     |> assign(:editing_flair, nil)}
  end

  def handle_event("create_flair", params, socket) do
    community_id = socket.assigns.community.id

    flair_params = %{
      "community_id" => community_id,
      "name" => params["name"],
      "is_mod_only" => params["is_mod_only"] == "on",
      "is_enabled" => params["is_enabled"] == "on"
    }

    case Messaging.create_community_flair(flair_params) do
      {:ok, _flair} ->
        flairs = Messaging.list_community_flairs(community_id)

        {:noreply,
         socket
         |> assign(:flairs, flairs)
         |> assign(:show_flair_modal, false)
         |> put_flash(:info, "Flair created successfully")}

      {:error, _changeset} ->
        {:noreply, notify_error(socket, "Failed to create flair")}
    end
  end

  def handle_event("update_flair", params, socket) do
    flair = Messaging.get_community_flair!(params["flair_id"])

    flair_params = %{
      "name" => params["name"],
      "is_mod_only" => params["is_mod_only"] == "on",
      "is_enabled" => params["is_enabled"] == "on"
    }

    case Messaging.update_community_flair(flair, flair_params) do
      {:ok, _flair} ->
        flairs = Messaging.list_community_flairs(socket.assigns.community.id)

        {:noreply,
         socket
         |> assign(:flairs, flairs)
         |> assign(:show_flair_modal, false)
         |> assign(:editing_flair, nil)
         |> put_flash(:info, "Flair updated successfully")}

      {:error, _changeset} ->
        {:noreply, notify_error(socket, "Failed to update flair")}
    end
  end

  def handle_event("delete_flair", %{"flair_id" => flair_id}, socket) do
    flair = Messaging.get_community_flair!(flair_id)

    case Messaging.delete_community_flair(flair) do
      {:ok, _} ->
        flairs = Messaging.list_community_flairs(socket.assigns.community.id)

        {:noreply,
         socket
         |> assign(:flairs, flairs)
         |> put_flash(:info, "Flair deleted successfully")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to delete flair")}
    end
  end

  # Private helpers

  defp notify_error(socket, message) do
    put_flash(socket, :error, message)
  end
end
