defmodule ElektrineWeb.EmailLive.Search do
  use ElektrineWeb, :live_view
  import ElektrineWeb.EmailLive.EmailHelpers

  alias Elektrine.Email
  alias Elektrine.Email.Cached
  alias Elektrine.Search.Cached, as: SearchCached

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user

    mailbox =
      case Email.get_user_mailbox(current_user.id) do
        nil ->
          {:ok, mailbox} = Email.create_mailbox(current_user)
          mailbox

        mailbox ->
          mailbox
      end

    storage_info = Elektrine.Accounts.Storage.get_storage_info(current_user.id)

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:mailbox, mailbox)
      |> assign(:page_title, "Search")
      |> assign(:search_query, "")
      |> assign(:search_results, nil)
      |> assign(:searching, false)
      |> assign(:unread_count, Cached.unread_count(mailbox.id))
      |> assign(:storage_info, storage_info)
      |> assign(:recent_searches, SearchCached.get_recent_searches(current_user.id))
      |> assign(:popular_searches, SearchCached.get_popular_searches())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    query = Map.get(params, "q", "")
    page = String.to_integer(Map.get(params, "page", "1"))

    socket = assign(socket, :search_query, query)

    socket =
      if String.trim(query) != "" do
        search_results =
          SearchCached.search_messages(
            socket.assigns.current_user.id,
            socket.assigns.mailbox.id,
            query,
            page,
            20
          )

        socket
        |> assign(:search_results, search_results)
        |> assign(:searching, false)
      else
        socket
        |> assign(:search_results, nil)
        |> assign(:searching, false)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    query = String.trim(query)

    if query != "" do
      {:noreply,
       socket
       |> assign(:searching, true)
       |> push_patch(to: ~p"/email/search?q=#{URI.encode(query)}")}
    else
      {:noreply,
       socket
       |> assign(:search_query, "")
       |> assign(:search_results, nil)
       |> assign(:searching, false)
       |> push_patch(to: ~p"/email/search")}
    end
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, nil)
     |> assign(:searching, false)
     |> push_patch(to: ~p"/email/search")}
  end

  @impl true
  def handle_event("quick_action", %{"action" => action, "message_id" => message_id}, socket) do
    case Email.get_user_message(String.to_integer(message_id), socket.assigns.current_user.id) do
      {:ok, message} ->
        case action do
          "archive" ->
            {:ok, _} = Email.archive_message(message)
            # Refresh search results
            if socket.assigns.search_results do
              search_results =
                Email.search_messages(
                  socket.assigns.mailbox.id,
                  socket.assigns.search_query,
                  socket.assigns.search_results.page,
                  20
                )

              {:noreply,
               socket
               |> assign(:search_results, search_results)
               |> notify_info("Message archived.")}
            else
              {:noreply, notify_info(socket, "Message archived.")}
            end

          "reply" ->
            {:noreply, push_navigate(socket, to: ~p"/email/compose?reply=#{message.id}")}

          "forward" ->
            {:noreply, push_navigate(socket, to: ~p"/email/compose?forward=#{message.id}")}

          _ ->
            {:noreply, socket}
        end

      {:error, _} ->
        {:noreply, notify_error(socket, "Message not found or access denied")}
    end
  end

  # Helper function for truncating subjects
  defp truncate_subject(subject, length) do
    if String.length(subject || "") > length do
      String.slice(subject || "", 0, length) <> "..."
    else
      subject || "(No Subject)"
    end
  end
end
