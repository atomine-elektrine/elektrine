defmodule ElektrineEmailWeb.EmailLive.Operations.ReplyLaterOperations do
  @moduledoc """
  Handles reply later (boomerang) operations for email inbox.
  """

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  import ElektrineEmailWeb.EmailLive.Operations.TabContent, only: [load_tab_content: 4]

  alias Elektrine.Email
  alias Elektrine.Email.Cached

  def handle_event("show_reply_later_modal", %{"id" => id}, socket) do
    case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(:reply_later_message, message)
         |> assign(:show_reply_later_modal, true)}

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found")}
    end
  end

  def handle_event("schedule_reply_later", %{"id" => id, "days" => days}, socket) do
    case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
      {:ok, message} ->
        days_int = String.to_integer(days)
        reply_at = DateTime.add(DateTime.utc_now(), days_int * 24 * 60 * 60, :second)

        {:ok, _} = Email.reply_later_message(message, reply_at)

        # Refresh current tab
        socket =
          load_tab_content(
            socket,
            socket.assigns.current_tab,
            %{"filter" => socket.assigns.current_filter},
            socket.assigns.pagination.page
          )

        {:noreply,
         socket
         |> assign(:show_reply_later_modal, false)
         |> assign(:reply_later_message, nil)
         |> assign(
           :boomerang_unread_count,
           Cached.unread_reply_later_count(socket.assigns.mailbox.id)
         )
         |> notify_info("Message scheduled for reply in #{days_int} day(s)")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found")}
    end
  end

  def handle_event("close_reply_later_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reply_later_modal, false)
     |> assign(:reply_later_message, nil)}
  end

  def handle_event("cancel_reply_later", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reply_later_modal, false)
     |> assign(:reply_later_message, nil)}
  end

  def handle_event("clear_reply_later", %{"id" => id}, socket) do
    case Email.get_user_message(String.to_integer(id), socket.assigns.current_user.id) do
      {:ok, message} ->
        {:ok, _} = Email.clear_reply_later(message)

        # Refresh current tab
        socket =
          load_tab_content(
            socket,
            socket.assigns.current_tab,
            %{"filter" => socket.assigns.current_filter},
            socket.assigns.pagination.page
          )

        {:noreply,
         socket
         |> assign(
           :boomerang_unread_count,
           Cached.unread_reply_later_count(socket.assigns.mailbox.id)
         )
         |> notify_info("Reply later schedule cleared")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found")}
    end
  end
end
