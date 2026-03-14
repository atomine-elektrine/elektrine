defmodule ElektrineWeb.EmailLive.Operations.ContactOperations do
  @moduledoc """
  Handles contact management operations for email inbox.
  """

  require Logger

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  def handle_event("contact_search", %{"value" => query}, socket) do
    Logger.info("Contact search: #{query}")

    contacts =
      if String.trim(query) == "" do
        Elektrine.Email.Contacts.list_contacts(socket.assigns.current_user.id)
      else
        Elektrine.Email.Contacts.search_contacts(socket.assigns.current_user.id, query)
      end

    Logger.info("Found #{length(contacts)} contacts")
    {:noreply, assign(socket, contacts: contacts, contact_search_query: query)}
  end

  def handle_event("new_contact", _params, socket) do
    {:noreply, assign(socket, show_contact_modal: true, editing_contact: nil)}
  end

  def handle_event("edit_contact", %{"id" => id}, socket) do
    contact = Elektrine.Email.Contacts.get_contact!(id)
    {:noreply, assign(socket, show_contact_modal: true, editing_contact: contact)}
  end

  def handle_event("cancel_contact", _params, socket) do
    {:noreply, assign(socket, show_contact_modal: false, editing_contact: nil)}
  end

  def handle_event("save_contact", params, socket) do
    favorite = params["favorite"] == "on"

    attrs =
      params
      |> Map.put("user_id", socket.assigns.current_user.id)
      |> Map.put("favorite", favorite)

    is_editing = !!socket.assigns.editing_contact

    result =
      if is_editing,
        do: Elektrine.Email.Contacts.update_contact(socket.assigns.editing_contact, attrs),
        else: Elektrine.Email.Contacts.create_contact(attrs)

    case result do
      {:ok, _} ->
        contacts = Elektrine.Email.Contacts.list_contacts(socket.assigns.current_user.id)

        message =
          if is_editing, do: "Contact updated successfully", else: "Contact added successfully"

        {:noreply,
         socket
         |> assign(:contacts, contacts)
         |> assign(:show_contact_modal, false)
         |> assign(:editing_contact, nil)
         |> notify_info(message)}

      {:error, _} ->
        message = if is_editing, do: "Failed to update contact", else: "Failed to add contact"
        {:noreply, notify_error(socket, message)}
    end
  end

  def handle_event("delete_contact", %{"id" => id}, socket) do
    contact = Elektrine.Email.Contacts.get_contact!(id)

    case Elektrine.Email.Contacts.delete_contact(contact) do
      {:ok, _} ->
        {:noreply,
         assign(
           socket,
           :contacts,
           Elektrine.Email.Contacts.list_contacts(socket.assigns.current_user.id)
         )
         |> notify_info("Contact deleted")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to delete contact")}
    end
  end

  def handle_event("toggle_favorite", %{"id" => id}, socket) do
    contact = Elektrine.Email.Contacts.get_contact!(id)
    {:ok, _} = Elektrine.Email.Contacts.toggle_favorite(contact)
    contacts = Elektrine.Email.Contacts.list_contacts(socket.assigns.current_user.id)
    {:noreply, assign(socket, :contacts, contacts)}
  end

  def handle_event("filter_by_group", %{"group_id" => group_id}, socket) do
    filter_id = if group_id == "", do: nil, else: String.to_integer(group_id)
    all = Elektrine.Email.Contacts.list_contacts(socket.assigns.current_user.id)
    contacts = if filter_id, do: Enum.filter(all, &(&1.group_id == filter_id)), else: all

    {:noreply,
     assign(socket, contacts: contacts, filter_group_id: filter_id, contact_search_query: "")}
  end

  def handle_event("new_group", _params, socket) do
    {:noreply, assign(socket, show_group_modal: true, editing_group: nil)}
  end

  def handle_event("cancel_group", _params, socket) do
    {:noreply, assign(socket, show_group_modal: false, editing_group: nil)}
  end

  def handle_event("save_group", params, socket) do
    attrs = Map.put(params, "user_id", socket.assigns.current_user.id)

    result =
      if socket.assigns.editing_group,
        do: Elektrine.Email.Contacts.update_contact_group(socket.assigns.editing_group, attrs),
        else: Elektrine.Email.Contacts.create_contact_group(attrs)

    case result do
      {:ok, _} ->
        groups = Elektrine.Email.Contacts.list_contact_groups(socket.assigns.current_user.id)

        {:noreply,
         socket
         |> assign(:groups, groups)
         |> assign(:show_group_modal, false)
         |> assign(:editing_group, nil)
         |> notify_info("Group saved")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to save group")}
    end
  end
end
