defmodule ElektrineSocialWeb.TimelineLive.Operations.UIOperations do
  @moduledoc """
  Handles UI-related events for the timeline live view.
  This includes stopping event propagation, closing modals and dropdowns.
  """

  import Phoenix.Component
  import Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: ElektrineWeb.Endpoint, router: ElektrineWeb.Router

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
  def handle_event("search_timeline", params, socket) do
    query =
      params
      |> extract_search_query()
      |> String.trim()

    path = search_path(socket, query)

    {:noreply, push_patch(socket, to: path)}
  end

  # Handles the clear_search event.
  # Resets search query and shows all posts.
  def handle_event("clear_search", _params, socket) do
    {:noreply, push_patch(socket, to: search_path(socket, ""))}
  end

  # Handles the toggle_mobile_filters event.
  # Toggles the mobile filter dropdown visibility.
  def handle_event("toggle_mobile_filters", _params, socket) do
    {:noreply, assign(socket, :show_mobile_filters, !socket.assigns.show_mobile_filters)}
  end

  defp search_path(socket, query) do
    params = %{
      "filter" => socket.assigns.current_filter,
      "view" => socket.assigns.timeline_filter
    }

    params =
      if query == "" do
        params
      else
        Map.put(params, "q", query)
      end

    ~p"/timeline?#{params}"
  end

  defp extract_search_query(%{"query" => query}) when is_binary(query), do: query
  defp extract_search_query(%{"value" => query}) when is_binary(query), do: query

  defp extract_search_query(params) when is_map(params) do
    Enum.find_value(params, "", fn
      {_key, %{"query" => query}} when is_binary(query) -> query
      {_key, %{"value" => query}} when is_binary(query) -> query
      _ -> nil
    end)
  end

  defp extract_search_query(_), do: ""
end
