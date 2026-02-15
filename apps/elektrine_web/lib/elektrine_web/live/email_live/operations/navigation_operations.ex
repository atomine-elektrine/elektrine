defmodule ElektrineWeb.EmailLive.Operations.NavigationOperations do
  @moduledoc """
  Handles navigation and pagination operations for email inbox.
  """

  import Phoenix.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  def handle_event("switch_tab", %{"tab" => tab} = params, socket) do
    socket = push_patch(socket, to: ~p"/email?tab=#{tab}")

    # Scroll to top when switching tabs
    socket = push_event(socket, "scroll-to-top", %{})

    # If focus_search is true, focus the search input after navigation
    socket =
      if params["focus_search"] == true || params["focus_search"] == "true" do
        push_event(socket, "focus-search-input", %{})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("goto_page", %{"page" => page}, socket) do
    current_tab = socket.assigns.current_tab
    current_filter = socket.assigns.current_filter

    url =
      if current_tab == "inbox" && current_filter != "inbox" do
        ~p"/email?tab=#{current_tab}&filter=#{current_filter}&page=#{page}"
      else
        ~p"/email?tab=#{current_tab}&page=#{page}"
      end

    {:noreply, push_patch(socket, to: url)}
  end

  def handle_event("next_page", _params, socket) do
    if socket.assigns.pagination.has_next do
      next_page = socket.assigns.pagination.page + 1
      handle_event("goto_page", %{"page" => to_string(next_page)}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("prev_page", _params, socket) do
    if socket.assigns.pagination.has_prev do
      prev_page = socket.assigns.pagination.page - 1
      handle_event("goto_page", %{"page" => to_string(prev_page)}, socket)
    else
      {:noreply, socket}
    end
  end
end
