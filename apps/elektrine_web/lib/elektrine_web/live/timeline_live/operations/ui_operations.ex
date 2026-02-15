defmodule ElektrineWeb.TimelineLive.Operations.UIOperations do
  @moduledoc """
  Handles UI-related events for the timeline live view.
  This includes stopping event propagation, closing modals and dropdowns.
  """

  import Phoenix.Component
  alias ElektrineWeb.TimelineLive.Operations.Helpers

  # Handles the stop_event event.
  # Used to stop event propagation without taking any action.
  def handle_event("stop_event", _params, socket) do
    {:noreply, socket}
  end

  # Handles the close_dropdown event.
  # Just acknowledges the event - dropdown will close automatically.
  def handle_event("close_dropdown", _params, socket) do
    {:noreply, socket}
  end

  # Handles the close_report_modal event.
  # Resets all report-related assigns in the socket.
  def handle_event("close_report_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, false)
     |> assign(:report_type, nil)
     |> assign(:report_id, nil)
     |> assign(:report_metadata, %{})}
  end

  # Handles the stop_propagation event.
  # Do nothing - just prevent event propagation to parent.
  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  # Catch-all for empty event names (from click propagation issues).
  def handle_event("", _params, socket) do
    {:noreply, socket}
  end

  # Handles the search_timeline event.
  # Filters posts based on search query.
  def handle_event("search_timeline", %{"query" => query}, socket) do
    query = String.trim(query)
    base_socket = Helpers.apply_timeline_filter(assign(socket, :search_query, ""))
    base_posts = base_socket.assigns.filtered_posts

    filtered_posts =
      if query == "" do
        base_posts
      else
        query_lower = String.downcase(query)

        Enum.filter(base_posts, fn post ->
          content_match =
            post.content &&
              String.contains?(String.downcase(post.content), query_lower)

          title_match =
            post.title &&
              String.contains?(String.downcase(post.title), query_lower)

          author_match =
            cond do
              post.sender ->
                String.contains?(
                  String.downcase(post.sender.username || ""),
                  query_lower
                ) ||
                  String.contains?(
                    String.downcase(post.sender.display_name || ""),
                    query_lower
                  )

              post.remote_actor ->
                String.contains?(
                  String.downcase(post.remote_actor.username || ""),
                  query_lower
                ) ||
                  String.contains?(
                    String.downcase(post.remote_actor.display_name || ""),
                    query_lower
                  )

              true ->
                false
            end

          content_match || title_match || author_match
        end)
      end

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:filtered_posts, filtered_posts)}
  end

  # Handles the clear_search event.
  # Resets search query and shows all posts.
  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(:search_query, "") |> Helpers.apply_timeline_filter()}
  end

  # Handles the toggle_mobile_filters event.
  # Toggles the mobile filter dropdown visibility.
  def handle_event("toggle_mobile_filters", _params, socket) do
    {:noreply, assign(socket, :show_mobile_filters, !socket.assigns.show_mobile_filters)}
  end
end
