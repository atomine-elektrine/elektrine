defmodule ElektrineWeb.ContactsLive.Index do
  use ElektrineWeb, :live_view

  alias Elektrine.Email.Contacts
  alias Elektrine.Email.Contact
  alias Elektrine.Email.ContactGroup

  import ElektrineWeb.ContactsLive.Operations.ContactOperations

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    # Set locale from session or user preference
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}:contacts")
    end

    contacts = Contacts.list_contacts(user.id)
    groups = Contacts.list_contact_groups(user.id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Contacts"))
     |> assign(:contacts, contacts)
     |> assign(:groups, groups)
     |> assign(:selected_group, nil)
     |> assign(:search_query, "")
     |> assign(:filtered_contacts, contacts)
     |> assign(:show_contact_modal, false)
     |> assign(:show_group_modal, false)
     |> assign(:editing_contact, nil)
     |> assign(:editing_group, nil)
     |> assign(:selected_contact, nil)
     |> assign(:contact_changeset, Contact.changeset(%Contact{}, %{}))
     |> assign(:group_changeset, ContactGroup.changeset(%ContactGroup{}, %{}))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, gettext("Contacts"))
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    user = socket.assigns.current_user
    contact = Contacts.get_contact!(user.id, id)

    socket
    |> assign(:page_title, contact.name)
    |> assign(:selected_contact, contact)
  end

  @impl true
  def handle_event(event, params, socket) do
    handle_contact_event(event, params, socket)
  end

  @impl true
  def handle_info({:contact_updated, contact}, socket) do
    contacts = update_contact_in_list(socket.assigns.contacts, contact)

    filtered =
      filter_contacts(contacts, socket.assigns.search_query, socket.assigns.selected_group)

    {:noreply,
     socket
     |> assign(:contacts, contacts)
     |> assign(:filtered_contacts, filtered)}
  end

  def handle_info({:contact_created, contact}, socket) do
    contacts = [contact | socket.assigns.contacts]

    filtered =
      filter_contacts(contacts, socket.assigns.search_query, socket.assigns.selected_group)

    {:noreply,
     socket
     |> assign(:contacts, contacts)
     |> assign(:filtered_contacts, filtered)}
  end

  def handle_info({:contact_deleted, contact_id}, socket) do
    contacts = Enum.reject(socket.assigns.contacts, &(&1.id == contact_id))

    filtered =
      filter_contacts(contacts, socket.assigns.search_query, socket.assigns.selected_group)

    {:noreply,
     socket
     |> assign(:contacts, contacts)
     |> assign(:filtered_contacts, filtered)
     |> assign(:selected_contact, nil)}
  end

  # Catch-all for other messages (presence updates, etc.)
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp update_contact_in_list(contacts, updated_contact) do
    Enum.map(contacts, fn c ->
      if c.id == updated_contact.id, do: updated_contact, else: c
    end)
  end

  defp filter_contacts(contacts, query, group) do
    contacts
    |> filter_by_search(query)
    |> filter_by_group(group)
    |> Enum.sort_by(& &1.name)
  end

  defp filter_by_search(contacts, ""), do: contacts

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
end
