defmodule ElektrineWeb.Components.UI.Dropdown do
  @moduledoc """
  Dropdown menu components for navigation and actions.

  This module provides reusable dropdown components using DaisyUI classes
  with support for icons, disabled states, and custom positioning.
  """
  use Phoenix.Component
  import ElektrineWeb.Components.UI.Icon

  @doc """
  Renders a dropdown menu with trigger and menu items.

  The dropdown uses DaisyUI's dropdown classes and supports various
  positioning options and custom styling.

  ## Examples

      <.dropdown>
        <:trigger>
          <button class="btn btn-ghost">
            Options
            <.icon name="hero-chevron-down" class="h-4 w-4 ml-1" />
          </button>
        </:trigger>
        <:menu>
          <.dropdown_item icon="hero-pencil" phx-click="edit">
            Edit
          </.dropdown_item>
          <.dropdown_divider />
          <.dropdown_item icon="hero-trash" class="text-error" phx-click="delete">
            Delete
          </.dropdown_item>
        </:menu>
      </.dropdown>

      <.dropdown class="dropdown-end">
        <:trigger>
          <button class="btn btn-circle btn-ghost">
            <.icon name="hero-ellipsis-vertical" class="h-5 w-5" />
          </button>
        </:trigger>
        <:menu>
          <.dropdown_item icon="hero-eye">View</.dropdown_item>
          <.dropdown_item icon="hero-share">Share</.dropdown_item>
        </:menu>
      </.dropdown>
  """
  attr :class, :string,
    default: nil,
    doc: "Additional CSS classes (use 'dropdown-end', 'dropdown-top', etc. for positioning)"

  attr :rest, :global, doc: "Additional HTML attributes"

  slot :trigger, required: true, doc: "Dropdown trigger button/element"
  slot :menu, required: true, doc: "Dropdown menu content"

  def dropdown(assigns) do
    ~H"""
    <div class={["dropdown", @class]} {@rest}>
      <div tabindex="0" role="button">
        {render_slot(@trigger)}
      </div>
      <ul
        tabindex="0"
        class="dropdown-content z-30 menu p-2 shadow-lg bg-base-100 rounded-box w-52 border border-base-300"
      >
        {render_slot(@menu)}
      </ul>
    </div>
    """
  end

  @doc """
  Renders a dropdown menu item with optional icon.

  Dropdown items can trigger Phoenix LiveView events, navigate to routes,
  or execute custom actions. Supports disabled state.

  ## Examples

      <.dropdown_item icon="hero-user" phx-click="view_profile">
        View Profile
      </.dropdown_item>

      <.dropdown_item icon="hero-cog-6-tooth" href={~p"/settings"}>
        Settings
      </.dropdown_item>

      <.dropdown_item
        icon="hero-trash"
        class="text-error"
        phx-click="delete"
        disabled
      >
        Delete (unavailable)
      </.dropdown_item>

      <.dropdown_item>
        <span class="font-semibold">No Icon Item</span>
      </.dropdown_item>
  """
  attr :icon, :string, default: nil, doc: "Optional Heroicon name (e.g., 'hero-user')"
  attr :disabled, :boolean, default: false, doc: "Whether the item is disabled"
  attr :class, :string, default: nil, doc: "Additional CSS classes"

  attr :rest, :global,
    include: ~w(phx-click phx-value-id href navigate patch),
    doc: "Additional HTML attributes including LiveView events"

  slot :inner_block, required: true, doc: "Menu item content"

  def dropdown_item(assigns) do
    ~H"""
    <li class={if @disabled, do: "disabled"}>
      <a class={["flex items-center gap-2", @class]} {@rest}>
        <%= if @icon do %>
          <.icon name={@icon} class="h-4 w-4" />
        <% end %>
        <span>{render_slot(@inner_block)}</span>
      </a>
    </li>
    """
  end

  @doc """
  Renders a divider between dropdown menu items.

  Used to visually separate groups of related menu items.

  ## Examples

      <.dropdown>
        <:trigger>
          <button class="btn">Menu</button>
        </:trigger>
        <:menu>
          <.dropdown_item icon="hero-home">Home</.dropdown_item>
          <.dropdown_item icon="hero-user">Profile</.dropdown_item>

          <.dropdown_divider />

          <.dropdown_item icon="hero-arrow-right-on-rectangle">
            Logout
          </.dropdown_item>
        </:menu>
      </.dropdown>
  """
  attr :class, :string, default: nil, doc: "Additional CSS classes"

  def dropdown_divider(assigns) do
    ~H"""
    <li class={@class}><hr class="my-1 border-base-300" /></li>
    """
  end
end
