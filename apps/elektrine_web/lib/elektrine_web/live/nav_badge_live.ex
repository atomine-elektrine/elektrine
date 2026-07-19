defmodule ElektrineWeb.NavBadgeLive do
  @moduledoc """
  Tiny badge island embedded with `live_render/3` on controller-rendered
  pages, so navbar notification badges live-update there just like on
  LiveView pages (where `NotificationCountHook` drives the same markup).

  Session keys:

    * `"user_id"` — the signed-in user's id (set server-side at render).
    * `"variant"` — `"bell"` for the navbar bell content, `"menu"` for the
      user-menu trailing badge.
  """
  use Phoenix.LiveView

  import ElektrineWeb.Components.Notification.Bell

  alias Elektrine.Notifications

  def mount(_params, session, socket) do
    user_id = session["user_id"]
    variant = session["variant"] || "bell"

    if connected?(socket) && user_id do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user_id}:notifications")
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user_id}:notification_count")
    end

    count = if user_id, do: Notifications.get_visible_unread_count(user_id), else: 0

    {:ok,
     socket
     |> assign(:user_id, user_id)
     |> assign(:variant, variant)
     |> assign(:notification_count, count), layout: false}
  end

  def render(assigns) do
    ~H"""
    <%= if @variant == "menu" do %>
      <.menu_badge count={@notification_count} />
    <% else %>
      <span id="nav-badge-toast-handler" phx-hook="NotificationHandler" class="hidden"></span>
      <.bell_badge count={@notification_count} />
    <% end %>
    """
  end

  def handle_info({:new_notification, notification}, socket) do
    socket = assign(socket, :notification_count, socket.assigns.notification_count + 1)

    socket =
      if socket.assigns.variant == "bell" do
        push_event(
          socket,
          "show_notification",
          ElektrineWeb.Live.Hooks.NotificationCountHook.notification_payload(notification)
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:notification_read, _notification_id}, socket) do
    {:noreply, assign(socket, :notification_count, max(socket.assigns.notification_count - 1, 0))}
  end

  def handle_info({:all_notifications_read, _}, socket) do
    {:noreply, assign(socket, :notification_count, 0)}
  end

  def handle_info(:all_notifications_read, socket) do
    {:noreply, assign(socket, :notification_count, 0)}
  end

  def handle_info({:notification_count_updated, new_count}, socket) do
    {:noreply, assign(socket, :notification_count, new_count)}
  end

  def handle_info(:notification_updated, socket) do
    count = Notifications.get_visible_unread_count(socket.assigns.user_id)
    {:noreply, assign(socket, :notification_count, count)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
