defmodule ElektrineWeb.SettingsLive.EmailPreferences do
  use ElektrineWeb, :live_view

  alias Elektrine.Email
  alias Elektrine.Email.ListTypes
  alias Elektrine.Email.Unsubscribes

  on_mount {ElektrineWeb.Live.AuthHooks, :require_authenticated_user}
  on_mount {ElektrineWeb.Live.Hooks.NotificationCountHook, :default}
  on_mount {ElektrineWeb.Live.Hooks.PresenceHook, :default}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # Get user's email addresses (mailbox + aliases)
    mailboxes = Email.get_user_mailboxes(user.id)
    aliases = Email.list_aliases(user.id)

    user_emails =
      (Enum.map(mailboxes, & &1.email) ++ Enum.map(aliases, & &1.email))
      |> Enum.uniq()

    # Get subscribable lists
    lists = ListTypes.subscribable_lists()

    # Get lists grouped by type
    lists_by_type = ListTypes.lists_by_type()

    # Get current unsubscribe status for each email/list combination (single batch query)
    list_ids = Enum.map(lists, & &1.id)
    unsubscribe_status = Unsubscribes.batch_check_unsubscribed(user_emails, list_ids)

    {:ok,
     socket
     |> assign(:page_title, "Email Preferences")
     |> assign(:user_emails, user_emails)
     |> assign(:lists, lists)
     |> assign(:lists_by_type, lists_by_type)
     |> assign(:unsubscribe_status, unsubscribe_status)}
  end

  @impl true
  def handle_event("toggle_subscription", %{"email" => email, "list_id" => list_id}, socket) do
    # Check current status
    currently_unsubscribed = Unsubscribes.unsubscribed?(email, list_id)

    result =
      if currently_unsubscribed do
        Unsubscribes.resubscribe(email, list_id)
      else
        Unsubscribes.unsubscribe(email, list_id: list_id, user_id: socket.assigns.current_user.id)
      end

    case result do
      {:ok, _} ->
        # Rebuild status (single batch query)
        list_ids = Enum.map(socket.assigns.lists, & &1.id)

        unsubscribe_status =
          Unsubscribes.batch_check_unsubscribed(socket.assigns.user_emails, list_ids)

        action = if currently_unsubscribed, do: "Resubscribed to", else: "Unsubscribed from"
        list_name = ListTypes.get_name(list_id)

        {:noreply,
         socket
         |> assign(:unsubscribe_status, unsubscribe_status)
         |> put_flash(:info, "#{action} #{list_name}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update subscription")}
    end
  end

  @impl true
  def handle_event("unsubscribe_all", %{"email" => email}, socket) do
    # Unsubscribe from all subscribable lists
    Enum.each(socket.assigns.lists, fn list ->
      Unsubscribes.unsubscribe(email, list_id: list.id, user_id: socket.assigns.current_user.id)
    end)

    # Rebuild status (single batch query)
    list_ids = Enum.map(socket.assigns.lists, & &1.id)

    unsubscribe_status =
      Unsubscribes.batch_check_unsubscribed(socket.assigns.user_emails, list_ids)

    {:noreply,
     socket
     |> assign(:unsubscribe_status, unsubscribe_status)
     |> put_flash(:info, "Unsubscribed from all mailing lists")}
  end

  @impl true
  def handle_event("resubscribe_all", %{"email" => email}, socket) do
    # Resubscribe to all lists
    Enum.each(socket.assigns.lists, fn list ->
      Unsubscribes.resubscribe(email, list.id)
    end)

    # Rebuild status (single batch query)
    list_ids = Enum.map(socket.assigns.lists, & &1.id)

    unsubscribe_status =
      Unsubscribes.batch_check_unsubscribed(socket.assigns.user_emails, list_ids)

    {:noreply,
     socket
     |> assign(:unsubscribe_status, unsubscribe_status)
     |> put_flash(:info, "Resubscribed to all mailing lists")}
  end

  # Helper functions for template
  defp type_badge_class(:transactional), do: "badge-error"
  defp type_badge_class(:marketing), do: "badge-primary"
  defp type_badge_class(:notifications), do: "badge-info"

  defp format_type(:transactional), do: "Transactional"
  defp format_type(:marketing), do: "Marketing"
  defp format_type(:notifications), do: "Notifications"
end
