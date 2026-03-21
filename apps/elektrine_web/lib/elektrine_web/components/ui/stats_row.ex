defmodule ElektrineWeb.Components.UI.StatsRow do
  @moduledoc """
  Compact stats row for short dashboard-like metrics.
  """

  use Phoenix.Component

  attr :stats, :list, required: true
  attr :class, :string, default: nil

  def stats_row(assigns) do
    ~H"""
    <div class={["grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3", @class]}>
      <%= for stat <- @stats do %>
        <div class="rounded-lg border border-base-content/10 bg-base-100/70 px-4 py-3">
          <div class="text-xs uppercase tracking-wide text-base-content/50">
            {stat[:label] || stat.label}
          </div>
          <div class="mt-1 text-sm font-medium">{stat[:value] || stat.value}</div>
          <div :if={stat[:hint]} class="mt-1 text-xs text-base-content/60">{stat[:hint]}</div>
        </div>
      <% end %>
    </div>
    """
  end
end
