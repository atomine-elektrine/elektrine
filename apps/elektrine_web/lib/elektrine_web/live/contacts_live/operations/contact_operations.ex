defmodule ElektrineWeb.ContactsLive.Operations.ContactOperations do
  @moduledoc """
  Handles contact-related events for the ContactsLive module.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]
  alias Elektrine.Email.Contacts
  alias Elektrine.Email.Contact
  alias Elektrine.Email.ContactGroup

  def handle_contact_event("search", %{"query" => query}, socket) do
    filtered = filter_contacts(socket.assigns.contacts, query, socket.assigns.selected_group)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:filtered_contacts, filtered)}
  end

  def handle_contact_event("select_group", %{"group" => "all"}, socket) do
    filtered = filter_contacts(socket.assigns.contacts, socket.assigns.search_query, nil)

    {:noreply,
     socket
     |> assign(:selected_group, nil)
     |> assign(:filtered_contacts, filtered)}
  end

  def handle_contact_event("select_group", %{"group" => "favorites"}, socket) do
    filtered = filter_contacts(socket.assigns.contacts, socket.assigns.search_query, "favorites")

    {:noreply,
     socket
     |> assign(:selected_group, "favorites")
     |> assign(:filtered_contacts, filtered)}
  end

  def handle_contact_event("select_group", %{"group" => group_id}, socket) do
    filtered = filter_contacts(socket.assigns.contacts, socket.assigns.search_query, group_id)

    {:noreply,
     socket
     |> assign(:selected_group, group_id)
     |> assign(:filtered_contacts, filtered)}
  end

  def handle_contact_event("new_contact", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_contact_modal, true)
     |> assign(:editing_contact, nil)
     |> assign(:contact_changeset, Contact.changeset(%Contact{}, %{}))}
  end

  def handle_contact_event("edit_contact", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    contact = Contacts.get_contact!(user.id, id)
    changeset = Contact.changeset(contact, %{})

    {:noreply,
     socket
     |> assign(:show_contact_modal, true)
     |> assign(:editing_contact, contact)
     |> assign(:contact_changeset, changeset)}
  end

  def handle_contact_event("cancel_contact_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_contact_modal, false)
     |> assign(:editing_contact, nil)}
  end

  def handle_contact_event("validate_contact", %{"contact" => params}, socket) do
    contact = socket.assigns.editing_contact || %Contact{}
    changeset = Contact.changeset(contact, params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :contact_changeset, changeset)}
  end

  def handle_contact_event("save_contact", %{"contact" => params}, socket) do
    user = socket.assigns.current_user

    result =
      if socket.assigns.editing_contact do
        Contacts.update_contact(socket.assigns.editing_contact, params)
      else
        params = Map.put(params, "user_id", user.id)
        Contacts.create_contact(params)
      end

    case result do
      {:ok, contact} ->
        contacts =
          if socket.assigns.editing_contact do
            Enum.map(socket.assigns.contacts, fn c ->
              if c.id == contact.id, do: contact, else: c
            end)
          else
            [contact | socket.assigns.contacts]
          end

        filtered =
          filter_contacts(contacts, socket.assigns.search_query, socket.assigns.selected_group)

        {:noreply,
         socket
         |> assign(:contacts, contacts)
         |> assign(:filtered_contacts, filtered)
         |> assign(:show_contact_modal, false)
         |> assign(:editing_contact, nil)
         |> put_flash(:info, gettext("Contact saved successfully"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :contact_changeset, changeset)}
    end
  end

  def handle_contact_event("delete_contact", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    contact = Contacts.get_contact!(user.id, id)

    case Contacts.delete_contact(contact) do
      {:ok, _} ->
        contacts = Enum.reject(socket.assigns.contacts, &(&1.id == id))

        filtered =
          filter_contacts(contacts, socket.assigns.search_query, socket.assigns.selected_group)

        {:noreply,
         socket
         |> assign(:contacts, contacts)
         |> assign(:filtered_contacts, filtered)
         |> assign(:selected_contact, nil)
         |> put_flash(:info, gettext("Contact deleted"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete contact"))}
    end
  end

  def handle_contact_event("toggle_favorite", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    contact = Contacts.get_contact!(user.id, id)

    case Contacts.toggle_favorite(contact) do
      {:ok, updated} ->
        contacts =
          Enum.map(socket.assigns.contacts, fn c ->
            if c.id == updated.id, do: updated, else: c
          end)

        filtered =
          filter_contacts(contacts, socket.assigns.search_query, socket.assigns.selected_group)

        selected =
          if socket.assigns.selected_contact && socket.assigns.selected_contact.id == updated.id do
            updated
          else
            socket.assigns.selected_contact
          end

        {:noreply,
         socket
         |> assign(:contacts, contacts)
         |> assign(:filtered_contacts, filtered)
         |> assign(:selected_contact, selected)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_contact_event("select_contact", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    contact = Contacts.get_contact!(user.id, id)

    {:noreply, assign(socket, :selected_contact, contact)}
  end

  def handle_contact_event("close_contact_detail", _params, socket) do
    {:noreply, assign(socket, :selected_contact, nil)}
  end

  # Group management
  def handle_contact_event("new_group", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_group_modal, true)
     |> assign(:editing_group, nil)
     |> assign(:group_changeset, ContactGroup.changeset(%ContactGroup{}, %{}))}
  end

  def handle_contact_event("edit_group", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    group = Contacts.get_contact_group!(user.id, id)
    changeset = ContactGroup.changeset(group, %{})

    {:noreply,
     socket
     |> assign(:show_group_modal, true)
     |> assign(:editing_group, group)
     |> assign(:group_changeset, changeset)}
  end

  def handle_contact_event("cancel_group_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_group_modal, false)
     |> assign(:editing_group, nil)}
  end

  def handle_contact_event("validate_group", %{"contact_group" => params}, socket) do
    group = socket.assigns.editing_group || %ContactGroup{}
    changeset = ContactGroup.changeset(group, params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :group_changeset, changeset)}
  end

  def handle_contact_event("save_group", %{"contact_group" => params}, socket) do
    user = socket.assigns.current_user

    result =
      if socket.assigns.editing_group do
        Contacts.update_contact_group(socket.assigns.editing_group, params)
      else
        params = Map.put(params, "user_id", user.id)
        Contacts.create_contact_group(params)
      end

    case result do
      {:ok, group} ->
        groups =
          if socket.assigns.editing_group do
            Enum.map(socket.assigns.groups, fn g ->
              if g.id == group.id, do: group, else: g
            end)
          else
            socket.assigns.groups ++ [group]
          end

        {:noreply,
         socket
         |> assign(:groups, groups)
         |> assign(:show_group_modal, false)
         |> assign(:editing_group, nil)
         |> put_flash(:info, gettext("Group saved successfully"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :group_changeset, changeset)}
    end
  end

  def handle_contact_event("delete_group", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    group = Contacts.get_contact_group!(user.id, id)

    case Contacts.delete_contact_group(group) do
      {:ok, _} ->
        groups = Enum.reject(socket.assigns.groups, &(&1.id == id))

        # Reset selected group if we just deleted it
        selected_group =
          if socket.assigns.selected_group == id, do: nil, else: socket.assigns.selected_group

        filtered =
          filter_contacts(socket.assigns.contacts, socket.assigns.search_query, selected_group)

        {:noreply,
         socket
         |> assign(:groups, groups)
         |> assign(:selected_group, selected_group)
         |> assign(:filtered_contacts, filtered)
         |> put_flash(:info, gettext("Group deleted"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete group"))}
    end
  end

  # Catch-all
  def handle_contact_event(event, params, socket) do
    require Logger
    Logger.warning("Unhandled contact event: #{event} with params: #{inspect(params)}")
    {:noreply, socket}
  end

  # Helper functions
  defp filter_contacts(contacts, query, group) do
    contacts
    |> filter_by_search(query)
    |> filter_by_group(group)
    |> Enum.sort_by(& &1.name)
  end

  defp filter_by_search(contacts, ""), do: contacts
  defp filter_by_search(contacts, nil), do: contacts

  defp filter_by_search(contacts, query) do
    query_lower = String.downcase(query)

    Enum.filter(contacts, fn c ->
      String.contains?(String.downcase(c.name || ""), query_lower) or
        String.contains?(String.downcase(c.email || ""), query_lower) or
        String.contains?(String.downcase(c.organization || ""), query_lower)
    end)
  end

  defp filter_by_group(contacts, nil), do: contacts

  defp filter_by_group(contacts, "favorites") do
    Enum.filter(contacts, & &1.favorite)
  end

  defp filter_by_group(contacts, group_id) when is_binary(group_id) do
    Enum.filter(contacts, &(&1.group_id == group_id))
  end

  defp filter_by_group(contacts, _), do: contacts

  defp gettext(msg), do: Gettext.gettext(ElektrineWeb.Gettext, msg)
end
