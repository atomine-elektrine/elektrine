defmodule ElektrineEmailWeb.EmailLive.SearchTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias ElektrineEmailWeb.EmailLive.Search

  test "search params and quick actions reject malformed numeric params" do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)
    socket = search_socket(user, mailbox)

    assert {:noreply, socket} =
             Search.handle_params(%{"q" => "invoice", "page" => "12abc"}, "/email/search", socket)

    assert socket.assigns.search_query == "invoice"
    assert socket.assigns.search_results.page == 1

    assert {:noreply, socket} =
             Search.handle_event(
               "quick_action",
               %{"action" => "archive", "message_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Message not found or access denied"
  end

  defp ensure_mailbox(user) do
    Email.get_user_mailbox(user.id) ||
      case Email.ensure_user_has_mailbox(user) do
        {:ok, mailbox} -> mailbox
        mailbox -> mailbox
      end
  end

  defp search_socket(user, mailbox) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        mailbox: mailbox,
        search_query: "",
        search_results: nil,
        searching: false
      }
    }
  end
end
