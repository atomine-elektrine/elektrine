defmodule ElektrineWeb.ENavLive do
  @moduledoc """
  E-nav island embedded with `live_render/3` on controller-rendered pages
  (canary, OIDC consent), so the product-navigation badges live-update
  there just like on LiveView pages.

  Session keys:

    * `"user_id"` — the signed-in user's id (set server-side at render).
    * `"active_tab"` — the active e-nav tab.
    * `"class"` — extra classes for the nav wrapper.
  """
  use Phoenix.LiveView

  import ElektrineWeb.Components.Platform.ENav

  alias Elektrine.Platform.ENav, as: PlatformENav

  def mount(_params, session, socket) do
    user = Elektrine.Accounts.get_user!(session["user_id"])

    if connected?(socket) do
      for topic <- [
            "user:#{user.id}",
            "user:#{user.id}:notifications",
            "user:#{user.id}:notification_count"
          ] do
        Phoenix.PubSub.subscribe(Elektrine.PubSub, topic)
      end
    end

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:active_tab, session["active_tab"] || "")
     |> assign(:class, session["class"] || "mb-6")
     |> assign(:badge_counts, PlatformENav.notification_badge_counts(user)), layout: false}
  end

  def render(assigns) do
    ~H"""
    <.e_nav
      active_tab={@active_tab}
      current_user={@current_user}
      badge_counts={@badge_counts}
      class={@class}
    />
    """
  end

  # Any count-affecting broadcast refreshes all badge counts; these events
  # are rare enough that a full recompute is fine.
  def handle_info(message, socket)
      when elem(message, 0) in [
             :new_notification,
             :notification_read,
             :all_notifications_read,
             :notification_count_updated,
             :unread_count_updated,
             :chat_unread_count_updated,
             :email_unread_count_updated,
             :friend_requests_updated,
             :storage_updated
           ] do
    {:noreply, refresh_counts(socket)}
  end

  def handle_info(message, socket)
      when message in [:all_notifications_read, :notification_updated] do
    {:noreply, refresh_counts(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_counts(socket) do
    assign(
      socket,
      :badge_counts,
      PlatformENav.notification_badge_counts(socket.assigns.current_user)
    )
  end
end
