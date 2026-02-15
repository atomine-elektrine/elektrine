defmodule ElektrineWeb.ListLive.Index do
  use ElektrineWeb, :live_view

  alias Elektrine.Social
  import ElektrineWeb.Components.Platform.ZNav

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if !user do
      {:ok, push_navigate(socket, to: ~p"/login")}
    else
      lists = Social.list_user_lists(user.id)
      public_lists = Social.list_public_lists(limit: 20)

      {:ok,
       socket
       |> assign(:page_title, "Lists")
       |> assign(:lists, lists)
       |> assign(:public_lists, public_lists)
       |> assign(:view_mode, "my_lists")
       |> assign(:show_create_form, false)
       |> assign(:new_list_name, "")
       |> assign(:new_list_description, "")
       |> assign(:search_query, "")}
    end
  end

  @impl true
  def handle_event("set_view_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  def handle_event("toggle_create_form", _params, socket) do
    {:noreply, assign(socket, :show_create_form, !socket.assigns.show_create_form)}
  end

  def handle_event("search_lists", %{"value" => query}, socket) do
    query = String.trim(query)

    public_lists =
      if String.length(query) >= 2 do
        Social.search_public_lists(query, limit: 20)
      else
        Social.list_public_lists(limit: 20)
      end

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:public_lists, public_lists)}
  end

  def handle_event("create_list", params, socket) do
    name = Map.get(params, "name", "")
    description = Map.get(params, "description", "")
    visibility = Map.get(params, "visibility", "private")

    attrs = %{
      user_id: socket.assigns.current_user.id,
      name: String.trim(name),
      description: String.trim(description),
      visibility: visibility
    }

    case Social.create_list(attrs) do
      {:ok, _list} ->
        lists = Social.list_user_lists(socket.assigns.current_user.id)

        {:noreply,
         socket
         |> assign(:lists, lists)
         |> assign(:show_create_form, false)
         |> assign(:new_list_name, "")
         |> assign(:new_list_description, "")
         |> put_flash(:info, "List created successfully")}

      {:error, changeset} ->
        error_msg =
          case changeset.errors do
            [{:name, {msg, _}} | _] -> msg
            _ -> "Failed to create list"
          end

        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  def handle_event("delete_list", %{"list_id" => list_id}, socket) do
    list_id = String.to_integer(list_id)

    case Social.get_user_list(socket.assigns.current_user.id, list_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "List not found")}

      list ->
        case Social.delete_list(list) do
          {:ok, _} ->
            lists = Social.list_user_lists(socket.assigns.current_user.id)

            {:noreply,
             socket
             |> assign(:lists, lists)
             |> put_flash(:info, "List deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete list")}
        end
    end
  end
end
