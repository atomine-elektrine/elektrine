defmodule ElektrineWeb.Components.Notification.Bell do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: ElektrineWeb.Gettext
  import ElektrineWeb.CoreComponents

  def notification_bell(assigns) do
    ~H"""
    <div class="indicator">
      <%= if @count > 0 do %>
        <span class="indicator-item badge badge-secondary badge-xs animate-pulse">
          {if @count > 99, do: "99+", else: @count}
        </span>
      <% end %>
      <.link
        href="/notifications"
        class="btn btn-ghost btn-circle btn-sm"
        title={gettext("Notifications")}
      >
        <.icon name="hero-bell" class="w-5 h-5" />
      </.link>
    </div>
    """
  end

  def notification_bell_live(assigns) do
    ~H"""
    <div class="indicator" id="notification-bell" phx-hook="NotificationBell">
      <%= if @count > 0 do %>
        <span class="indicator-item badge badge-secondary badge-xs animate-pulse">
          {if @count > 99, do: "99+", else: @count}
        </span>
      <% end %>
      <.link
        href="/notifications"
        class="btn btn-ghost btn-circle btn-sm"
        title={gettext("Notifications") <> if(@count > 0, do: " (#{@count})", else: "")}
      >
        <%= if @count > 0 do %>
          <.icon name="hero-bell-alert" class="w-5 h-5" />
        <% else %>
          <.icon name="hero-bell" class="w-5 h-5" />
        <% end %>
      </.link>
    </div>
    """
  end
end
