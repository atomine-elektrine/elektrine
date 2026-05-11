defmodule ElektrineSocialWeb.DiscussionsLive.Operations.FlairOperations do
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
    if can_manage_flairs?(socket) do
      {:noreply,
       socket
       |> assign(:show_flair_modal, true)
       |> assign(:editing_flair, nil)}
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("edit_flair", %{"flair_id" => flair_id}, socket) do
    case get_manageable_flair(socket, flair_id) do
      {:ok, flair} ->
        {:noreply,
         socket
         |> assign(:show_flair_modal, true)
         |> assign(:editing_flair, flair)}

      {:error, _reason} ->
        {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("cancel_flair", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_flair_modal, false)
     |> assign(:editing_flair, nil)}
  end

  def handle_event("create_flair", params, socket) do
    if can_manage_flairs?(socket) do
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
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("update_flair", params, socket) do
    case get_manageable_flair(socket, params["flair_id"]) do
      {:ok, flair} ->
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

      {:error, _reason} ->
        {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("delete_flair", %{"flair_id" => flair_id}, socket) do
    case get_manageable_flair(socket, flair_id) do
      {:ok, flair} ->
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

      {:error, _reason} ->
        {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  # Private helpers

  defp notify_error(socket, message) do
    put_flash(socket, :error, message)
  end

  defp get_manageable_flair(socket, flair_id) do
    with true <- can_manage_flairs?(socket),
         {:ok, flair} <- fetch_flair(flair_id),
         true <- flair.community_id == socket.assigns.community.id do
      {:ok, flair}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp fetch_flair(flair_id) do
    flair_id
    |> parse_flair_id()
    |> case do
      {:ok, id} ->
        {:ok, Messaging.get_community_flair!(id)}

      :error ->
        {:error, :invalid_flair}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp parse_flair_id(id) when is_integer(id), do: {:ok, id}

  defp parse_flair_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_flair_id(_), do: :error

  defp can_manage_flairs?(socket) do
    socket.assigns[:is_moderator] == true ||
      match?(%{is_admin: true}, socket.assigns[:current_user])
  end
end
