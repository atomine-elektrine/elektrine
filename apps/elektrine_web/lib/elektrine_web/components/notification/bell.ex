defmodule ElektrineWeb.Components.Notification.Bell do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: ElektrineWeb.Gettext
  import ElektrineWeb.CoreComponents

  @doc """
  Inner content of the navbar notification bell: the pulsing unread badge plus
  the bell / bell-alert icon. Rendered by the layouts on LiveView pages and by
  `ElektrineWeb.NavBadgeLive` inside controller-rendered pages.
  """
  attr :count, :integer, default: 0

  def bell_badge(assigns) do
    ~H"""
    <%= if @count > 0 do %>
      <span class="indicator-item indicator-top indicator-end flex h-4 w-4 pointer-events-none -translate-x-0.5 translate-y-0.5">
        <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-error opacity-75">
        </span>
        <span class="relative inline-flex items-center justify-center rounded-full h-4 w-4 bg-error text-error-content text-[9px] font-medium">
          {if @count > 99, do: "99+", else: @count}
        </span>
      </span>
    <% end %>

    <%= if @count > 0 do %>
      <.icon name="hero-bell-alert" class="w-5 h-5" />
    <% else %>
      <.icon name="hero-bell" class="w-5 h-5" />
    <% end %>
    """
  end

  @doc """
  Trailing unread badge for the user-menu Notifications item.
  """
  attr :count, :integer, default: 0

  def menu_badge(assigns) do
    ~H"""
    <%= if @count > 0 do %>
      <span class="ml-auto badge badge-xs badge-error text-error-content">
        {if @count > 99, do: "99+", else: @count}
      </span>
    <% end %>
    """
  end
end
