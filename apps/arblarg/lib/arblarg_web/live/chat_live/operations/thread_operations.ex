defmodule ArblargWeb.ChatLive.Operations.ThreadOperations do
  @moduledoc """
  Handles chat thread operations: creating threads from messages, the
  right-hand thread panel (thread list + single-thread view with composer),
  archiving, and the PubSub events that keep open panels in sync.
  """

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  alias ArblargWeb.ChatLive.State
  alias Elektrine.Messaging

  ## Events

  def handle_event("toggle_thread_panel", _params, socket) do
    threads = socket.assigns.threads

    if threads.show_panel do
      {:noreply, assign(socket, :threads, %{threads | show_panel: false})}
    else
      {:noreply,
       assign(socket, :threads, refresh_thread_lists(%{threads | show_panel: true}, socket))}
    end
  end

  def handle_event("close_thread_panel", _params, socket) do
    threads = socket.assigns.threads

    {:noreply,
     assign(socket, :threads, %{threads | show_panel: false, active: nil, messages: []})}
  end

  def handle_event("back_to_thread_list", _params, socket) do
    threads = socket.assigns.threads

    {:noreply, assign(socket, :threads, %{threads | active: nil, messages: [], composer: ""})}
  end

  def handle_event("toggle_archived_threads", _params, socket) do
    threads = socket.assigns.threads
    show_archived = !threads.show_archived

    archived =
      if show_archived and selected_conversation_id(socket) do
        Messaging.list_chat_threads(selected_conversation_id(socket), :archived)
      else
        threads.archived
      end

    {:noreply,
     assign(socket, :threads, %{threads | show_archived: show_archived, archived: archived})}
  end

  def handle_event("create_thread", %{"message_id" => message_id}, socket) do
    user_id = socket.assigns.current_user.id

    case Messaging.create_chat_thread_from_message(message_id, user_id) do
      {:ok, thread} ->
        {:noreply,
         socket
         |> hide_message_context_menu()
         |> open_thread(thread)
         |> notify_info("Thread created")}

      {:error, :thread_exists} ->
        {:noreply,
         socket
         |> hide_message_context_menu()
         |> notify_info("This message already has a thread")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> hide_message_context_menu()
         |> notify_error("You don't have permission to create threads here")}

      {:error, :unsupported_conversation_type} ->
        {:noreply,
         socket
         |> hide_message_context_menu()
         |> notify_error("Threads are only available in channels")}

      {:error, _} ->
        {:noreply,
         socket
         |> hide_message_context_menu()
         |> notify_error("Failed to create thread")}
    end
  end

  def handle_event("open_thread", %{"thread_id" => thread_id}, socket) do
    with {:ok, thread_id} <- parse_positive_int(thread_id),
         %{} = thread <- Messaging.get_chat_thread(thread_id),
         true <- thread.conversation_id == selected_conversation_id(socket) do
      {:noreply, open_thread(socket, thread)}
    else
      _ -> {:noreply, notify_error(socket, "Thread not found")}
    end
  end

  def handle_event("archive_thread", %{"thread_id" => thread_id}, socket) do
    with {:ok, thread_id} <- parse_positive_int(thread_id),
         {:ok, _thread} <-
           Messaging.archive_chat_thread(thread_id, socket.assigns.current_user.id) do
      {:noreply, notify_info(socket, "Thread archived")}
    else
      {:error, :unauthorized} ->
        {:noreply, notify_error(socket, "You don't have permission to archive this thread")}

      _ ->
        {:noreply, notify_error(socket, "Failed to archive thread")}
    end
  end

  def handle_event("unarchive_thread", %{"thread_id" => thread_id}, socket) do
    with {:ok, thread_id} <- parse_positive_int(thread_id),
         {:ok, _thread} <-
           Messaging.unarchive_chat_thread(thread_id, socket.assigns.current_user.id) do
      {:noreply, notify_info(socket, "Thread reopened")}
    else
      {:error, :unauthorized} ->
        {:noreply, notify_error(socket, "You don't have permission to reopen this thread")}

      _ ->
        {:noreply, notify_error(socket, "Failed to reopen thread")}
    end
  end

  def handle_event("update_thread_composer", %{"message" => value}, socket) do
    threads = socket.assigns.threads
    {:noreply, assign(socket, :threads, %{threads | composer: value})}
  end

  def handle_event("send_thread_message", %{"message" => content}, socket) do
    threads = socket.assigns.threads
    content = String.trim(content || "")

    cond do
      is_nil(threads.active) ->
        {:noreply, socket}

      content == "" ->
        {:noreply, socket}

      true ->
        case Messaging.create_chat_thread_message(
               threads.active.id,
               socket.assigns.current_user.id,
               content
             ) do
          {:ok, _message} ->
            {:noreply, assign(socket, :threads, %{socket.assigns.threads | composer: ""})}

          {:error, :thread_archived} ->
            {:noreply, notify_error(socket, "This thread is archived")}

          {:error, :unauthorized} ->
            {:noreply, notify_error(socket, "You can't send messages here")}

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to send message")}
        end
    end
  end

  ## PubSub info routing (chained before the generic message info router)

  def route_info(info, socket) do
    case info do
      {:thread_created, thread} ->
        {:handled, handle_thread_upserted(socket, thread)}

      {:thread_updated, thread} ->
        {:handled, handle_thread_upserted(socket, thread)}

      {:thread_archived, thread} ->
        {:handled, handle_thread_upserted(socket, thread)}

      {:new_thread_message, message} ->
        {:handled, handle_new_thread_message(socket, message)}

      _ ->
        :unhandled
    end
  end

  ## Helpers used by the template

  @doc """
  Returns the thread rooted at `message_id`, if any (active or archived).
  """
  def thread_for_message(%State.Threads{} = threads, message_id) do
    Enum.find(threads.list ++ threads.archived, &(&1.root_message_id == message_id))
  end

  def thread_for_message(_threads, _message_id), do: nil

  ## Internal

  defp handle_thread_upserted(socket, thread) do
    if thread.conversation_id == selected_conversation_id(socket) do
      threads = socket.assigns.threads

      active =
        if threads.active && threads.active.id == thread.id do
          thread
        else
          threads.active
        end

      list = upsert_sorted(threads.list, thread, is_nil(thread.archived_at))

      archived =
        if threads.show_archived do
          upsert_sorted(threads.archived, thread, not is_nil(thread.archived_at))
        else
          threads.archived
        end

      {:noreply,
       assign(socket, :threads, %{threads | list: list, archived: archived, active: active})}
    else
      {:noreply, socket}
    end
  end

  defp handle_new_thread_message(socket, message) do
    threads = socket.assigns.threads

    if threads.active && threads.active.id == message.thread_id do
      messages =
        if Enum.any?(threads.messages, &(&1.id == message.id)) do
          threads.messages
        else
          threads.messages ++ [message]
        end

      {:noreply, assign(socket, :threads, %{threads | messages: messages})}
    else
      {:noreply, socket}
    end
  end

  defp open_thread(socket, thread) do
    threads = socket.assigns.threads
    messages = Messaging.list_chat_thread_messages(thread.id)

    assign(socket, :threads, %{
      threads
      | show_panel: true,
        active: thread,
        messages: messages,
        composer: "",
        list: refresh_active_list(socket)
    })
  end

  defp refresh_thread_lists(threads, socket) do
    case selected_conversation_id(socket) do
      nil ->
        threads

      conversation_id ->
        archived =
          if threads.show_archived do
            Messaging.list_chat_threads(conversation_id, :archived)
          else
            threads.archived
          end

        %{threads | list: Messaging.list_chat_threads(conversation_id), archived: archived}
    end
  end

  defp refresh_active_list(socket) do
    case selected_conversation_id(socket) do
      nil -> socket.assigns.threads.list
      conversation_id -> Messaging.list_chat_threads(conversation_id)
    end
  end

  defp upsert_sorted(threads, thread, belongs?) do
    without = Enum.reject(threads, &(&1.id == thread.id))

    if belongs? do
      [thread | without]
      |> Enum.sort_by(&(&1.last_activity_at || &1.inserted_at), {:desc, DateTime})
    else
      without
    end
  end

  defp selected_conversation_id(socket) do
    case socket.assigns.conversation.selected do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_positive_int(_value), do: :error

  defp hide_message_context_menu(socket) do
    assign(socket, :context_menu, %{
      socket.assigns.context_menu
      | message: nil,
        selected_text: nil
    })
  end
end
