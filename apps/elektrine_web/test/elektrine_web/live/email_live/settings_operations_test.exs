defmodule ElektrineEmailWeb.EmailLive.SettingsOperationsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias ElektrineEmailWeb.EmailLive.Operations.AliasOperations
  alias ElektrineEmailWeb.EmailLive.Operations.ContactOperations
  alias ElektrineEmailWeb.EmailLive.Operations.SelectionOperations
  alias ElektrineEmailWeb.EmailLive.Operations.TabContent
  alias ElektrineEmailWeb.EmailLive.Settings.ContentSettings
  alias ElektrineEmailWeb.EmailLive.Settings.DomainSettings
  alias ElektrineEmailWeb.EmailLive.Settings.FilterSettings
  alias ElektrineEmailWeb.EmailLive.Settings.SenderSettings

  test "domain settings reject malformed ids" do
    socket = settings_socket()

    assert {:noreply, socket} =
             DomainSettings.handle_event("toggle_alias", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Alias not found"

    assert {:noreply, socket} =
             DomainSettings.handle_event("delete_alias", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Alias not found"

    assert {:noreply, socket} =
             DomainSettings.handle_event("verify_custom_domain", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Custom domain not found"

    assert {:noreply, socket} =
             DomainSettings.handle_event("sync_custom_domain_dkim", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Custom domain not found"

    assert {:noreply, socket} =
             DomainSettings.handle_event("delete_custom_domain", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Custom domain not found"
  end

  test "content settings reject malformed ids" do
    socket = settings_socket()

    assert {:noreply, socket} =
             ContentSettings.handle_event("show_template_modal", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Template not found"

    assert {:noreply, socket} =
             ContentSettings.handle_event("delete_template", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Template not found"

    assert {:noreply, socket} =
             ContentSettings.handle_event("delete_folder", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Folder not found"

    assert {:noreply, socket} =
             ContentSettings.handle_event("delete_label", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Label not found"

    assert {:noreply, socket} =
             ContentSettings.handle_event("delete_export", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Export not found"
  end

  test "filter and sender settings reject malformed ids" do
    socket = settings_socket()

    assert {:noreply, socket} =
             FilterSettings.handle_event("show_filter_modal", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Filter not found"

    assert {:noreply, socket} =
             FilterSettings.handle_event("toggle_filter", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Filter not found"

    assert {:noreply, socket} =
             FilterSettings.handle_event("delete_filter", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Filter not found"

    assert {:noreply, socket} =
             SenderSettings.handle_event("unblock_sender", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Blocked sender not found"

    assert {:noreply, socket} =
             SenderSettings.handle_event("remove_safe_sender", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Safe sender not found"
  end

  test "email inbox operations reject malformed ids" do
    socket = settings_socket()

    assert {:noreply, socket} =
             AliasOperations.handle_event("edit_alias", %{"id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Alias not found"

    assert {:noreply, socket} =
             ContactOperations.handle_event("filter_by_group", %{"group_id" => "12abc"}, socket)

    assert socket.assigns.filter_group_id == nil

    socket =
      socket
      |> Phoenix.Component.assign(:messages, [%{id: 1}])
      |> Phoenix.Component.assign(:selected_messages, [])
      |> Phoenix.Component.assign(:select_all, false)

    assert {:noreply, socket} =
             SelectionOperations.handle_event(
               "toggle_message_selection",
               %{"message_id" => "12abc"},
               socket
             )

    assert socket.assigns.selected_messages == []
    refute socket.assigns.select_all
  end

  test "folder tab rejects malformed folder ids" do
    socket = settings_socket()
    mailbox = ensure_mailbox(socket.assigns.current_user)
    socket = Phoenix.Component.assign(socket, :mailbox, mailbox)

    socket = TabContent.load_tab_content(socket, "folder", %{"folder_id" => "12abc"})

    assert socket.assigns.current_folder_id == nil
    assert socket.assigns.messages == []
    assert socket.assigns.pagination.total_count == 0
  end

  defp settings_socket do
    user = AccountsFixtures.user_fixture()

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        aliases: [],
        templates: [],
        folders: [],
        custom_folders: [],
        labels: [],
        exports: [],
        filters: [],
        blocked_senders: [],
        safe_senders: [],
        contacts: [],
        groups: []
      }
    }
  end

  defp ensure_mailbox(user) do
    Email.get_user_mailbox(user.id) ||
      case Email.ensure_user_has_mailbox(user) do
        {:ok, mailbox} -> mailbox
        mailbox -> mailbox
      end
  end
end
