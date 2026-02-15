defmodule ElektrineWeb.Components.UI.Card do
  @moduledoc """
  Card components for displaying content in structured containers.

  This module provides reusable card components with consistent styling
  across the application, including generic cards, statistic cards, and
  information cards with proper dark theme support.
  """
  use Phoenix.Component
  import ElektrineWeb.Components.UI.Icon

  @doc """
  Renders a generic card container with optional title, body, and actions.

  Cards use DaisyUI classes and support dark theme through base-content
  and base-200/base-300 color schemes.

  ## Examples

      <.card>
        <:title>User Information</:title>
        <:body>
          <p>This is the card content</p>
        </:body>
        <:actions>
          <button class="btn btn-primary">Save</button>
        </:actions>
      </.card>

      <.card class="mb-4">
        <:body>
          <p>Simple card with just body content</p>
        </:body>
      </.card>
  """
  attr :class, :string, default: nil, doc: "Additional CSS classes for the card container"
  attr :rest, :global, doc: "Additional HTML attributes"

  slot :title, doc: "Card title/header content"
  slot :body, required: true, doc: "Main card content"
  slot :actions, doc: "Card action buttons or footer content"

  def card(assigns) do
    ~H"""
    <div class={["card glass-card shadow-lg border border-base-300", @class]} {@rest}>
      <div class="card-body">
        <%= if @title != [] do %>
          <h2 class="card-title text-base-content">{render_slot(@title)}</h2>
        <% end %>

        <div class="flex-1">{render_slot(@body)}</div>

        <%= if @actions != [] do %>
          <div class="card-actions justify-end mt-4">
            {render_slot(@actions)}
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a statistics display card with icon, label, value, and optional description.

  Commonly used in dashboards to display key metrics and statistics.

  ## Examples

      <.stat_card
        icon="hero-users"
        icon_color="text-primary"
        label="Total Users"
        value="1,234"
      />

      <.stat_card
        icon="hero-envelope"
        icon_color="text-success"
        label="Messages Sent"
        value="5,678"
        description="Last 24 hours"
      />

      <.stat_card
        icon="hero-chart-bar"
        icon_color="text-warning"
        label="Active Sessions"
        value={@session_count}
        description={@session_description}
        class="stat-lg"
      />
  """
  attr :icon, :string, required: true, doc: "Heroicon name (e.g., 'hero-users')"
  attr :icon_color, :string, default: "text-primary", doc: "Tailwind color class for the icon"
  attr :label, :string, required: true, doc: "Statistic label/title"
  attr :value, :any, required: true, doc: "Statistic value (string or number)"
  attr :description, :string, default: nil, doc: "Optional description text below the value"
  attr :class, :string, default: nil, doc: "Additional CSS classes"
  attr :rest, :global, doc: "Additional HTML attributes"

  def stat_card(assigns) do
    ~H"""
    <div class={["stat bg-base-200 rounded-lg p-4 border border-base-300", @class]} {@rest}>
      <div class={"stat-figure #{@icon_color}"}>
        <.icon name={@icon} class="h-8 w-8" />
      </div>
      <div class="stat-title text-base-content/60">{@label}</div>
      <div class="stat-value text-base-content">{@value}</div>
      <%= if @description do %>
        <div class="stat-desc text-base-content/50">{@description}</div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders an information card with icon and content.

  Used for displaying important information, alerts, or contextual content
  with an accompanying icon.

  ## Examples

      <.info_card icon="hero-information-circle" icon_color="text-info">
        <p>This is an informational message</p>
      </.info_card>

      <.info_card
        icon="hero-exclamation-triangle"
        icon_color="text-warning"
        class="mb-4"
      >
        <p class="font-semibold">Warning</p>
        <p>Please review this information carefully</p>
      </.info_card>

      <.info_card icon="hero-check-circle" icon_color="text-success">
        <p>Operation completed successfully!</p>
      </.info_card>
  """
  attr :icon, :string, required: true, doc: "Heroicon name (e.g., 'hero-information-circle')"
  attr :icon_color, :string, default: "text-info", doc: "Tailwind color class for the icon"
  attr :class, :string, default: nil, doc: "Additional CSS classes"
  attr :rest, :global, doc: "Additional HTML attributes"

  slot :inner_block, required: true, doc: "Card content"

  def info_card(assigns) do
    ~H"""
    <div class={["card bg-base-200 border border-base-300 rounded-lg", @class]} {@rest}>
      <div class="card-body p-4">
        <div class="flex items-start gap-4">
          <div class={"flex-shrink-0 #{@icon_color}"}>
            <.icon name={@icon} class="h-6 w-6" />
          </div>
          <div class="flex-1 text-base-content">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </div>
    """
  end
end
