defmodule ElektrineWeb.Components.UI.Dropdown do
  @moduledoc """
  Dropdown menu components for navigation and actions.
  """

  use Phoenix.Component

  import ElektrineWeb.Components.UI.Icon

  @doc """
  Renders a dropdown menu with trigger and menu items.
  """
  attr :class, :string,
    default: nil,
    doc: "Additional CSS classes (use 'dropdown-end', 'dropdown-top', etc. for positioning)"

  attr :rest, :global, doc: "Additional HTML attributes"
  attr :menu_class, :string, default: nil, doc: "Additional classes for dropdown menu shell"

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
        class={["dropdown-content floating-menu z-30 menu p-2 rounded-box w-52", @menu_class]}
      >
        {render_slot(@menu)}
      </ul>
    </div>
    """
  end

  @doc """
  Renders a dropdown menu item with optional icon.
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
  """
  attr :class, :string, default: nil, doc: "Additional CSS classes"

  def dropdown_divider(assigns) do
    ~H"""
    <li class={@class}><hr class="my-1 border-base-300" /></li>
    """
  end
end
