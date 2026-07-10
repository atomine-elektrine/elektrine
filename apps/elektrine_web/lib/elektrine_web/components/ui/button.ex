defmodule ElektrineWeb.Components.UI.Button do
  @moduledoc """
  Button component for user interactions.

  Renders a `<button>` element, or a `Phoenix.Component.link/1` when one of
  `navigate`, `patch`, or `href` is set, so links styled as buttons share the
  same variants and sizes as real buttons.

  This component is the single source of truth for button styling: templates
  should not hand-write `btn btn-*` class strings.
  """
  use Phoenix.Component

  alias ElektrineWeb.Components.UI.Loading

  @variants ~w(primary secondary accent neutral ghost error success warning info default)
  @sizes ~w(xs sm md lg)

  @doc """
  Renders a button or a link styled as a button.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" class="ml-2">Send!</.button>
      <.button variant="secondary">Cancel</.button>
      <.button variant="error" outline size="sm">Delete</.button>
      <.button navigate={~p"/settings"} variant="ghost" size="sm">Settings</.button>
      <.button href="https://example.com" target="_blank" variant="default">Docs</.button>
      <.button loading={true}>Saving...</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil

  attr :variant, :string,
    default: "primary",
    values: @variants,
    doc: "`default` renders a plain DaisyUI `btn` with no variant class"

  attr :outline, :boolean, default: false, doc: "Combine the variant with `btn-outline`"
  attr :size, :string, default: "md", values: @sizes
  attr :navigate, :string, default: nil, doc: "Render as a `<.link navigate={...}>`"
  attr :patch, :string, default: nil, doc: "Render as a `<.link patch={...}>`"
  attr :href, :any, default: nil, doc: "Render as a `<.link href={...}>`"
  attr :method, :string, default: "get", doc: "HTTP method for `href` links"
  attr :loading, :boolean, default: false, doc: "Show loading spinner"
  attr :loading_text, :string, default: nil, doc: "Text to show when loading"
  attr :icon_left, :string, default: nil, doc: "Heroicon name for left icon"
  attr :icon_right, :string, default: nil, doc: "Heroicon name for right icon"

  attr :rest, :global,
    include: ~w(disabled form name value target rel download phx-click phx-disable-with)

  slot :inner_block, required: true

  def button(%{navigate: navigate, patch: patch, href: href} = assigns)
      when not is_nil(navigate) or not is_nil(patch) or not is_nil(href) do
    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      href={@href}
      method={@method}
      class={button_classes(assigns)}
      {@rest}
    >
      <%= if @icon_left do %>
        <ElektrineWeb.Components.UI.Icon.icon name={@icon_left} class={icon_size_class(@size)} />
      <% end %>
      {render_slot(@inner_block)}
      <%= if @icon_right do %>
        <ElektrineWeb.Components.UI.Icon.icon name={@icon_right} class={icon_size_class(@size)} />
      <% end %>
    </.link>
    """
  end

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={button_classes(assigns)}
      disabled={@loading || assigns[:disabled]}
      aria-busy={@loading}
      {@rest}
    >
      <%= if @loading do %>
        <Loading.spinner size={@size} />
        <span>{@loading_text || render_slot(@inner_block)}</span>
      <% else %>
        <%= if @icon_left do %>
          <ElektrineWeb.Components.UI.Icon.icon name={@icon_left} class={icon_size_class(@size)} />
        <% end %>
        {render_slot(@inner_block)}
        <%= if @icon_right do %>
          <ElektrineWeb.Components.UI.Icon.icon name={@icon_right} class={icon_size_class(@size)} />
        <% end %>
      <% end %>
    </button>
    """
  end

  @doc """
  Renders an icon-only button.

  ## Examples

      <.icon_button icon="hero-plus" label="Add" />
      <.icon_button icon="hero-trash" variant="error" label="Delete" />
  """
  attr :icon, :string, required: true, doc: "Heroicon name"
  attr :class, :string, default: nil
  attr :variant, :string, default: "ghost", values: @variants
  attr :outline, :boolean, default: false
  attr :size, :string, default: "md", values: @sizes
  attr :label, :string, default: nil, doc: "Accessibility label"
  attr :rest, :global, include: ~w(disabled phx-click)

  def icon_button(assigns) do
    ~H"""
    <button
      type="button"
      class={["btn btn-circle", button_modifier_classes(assigns), "p-2.5 sm:p-2", @class]}
      aria-label={@label}
      {@rest}
    >
      <ElektrineWeb.Components.UI.Icon.icon name={@icon} class={icon_size_class(@size)} />
    </button>
    """
  end

  # Private helpers

  defp button_classes(assigns) do
    [
      "btn",
      button_modifier_classes(assigns),
      assigns[:loading] && "btn-loading pointer-events-none",
      assigns.class
    ]
  end

  defp button_modifier_classes(assigns) do
    [
      assigns.outline && "btn-outline",
      variant_class(assigns.variant),
      size_class(assigns.size)
    ]
  end

  defp variant_class("primary"), do: "btn-primary"
  defp variant_class("secondary"), do: "btn-secondary"
  defp variant_class("accent"), do: "btn-accent"
  defp variant_class("neutral"), do: "btn-neutral"
  defp variant_class("ghost"), do: "btn-ghost"
  defp variant_class("error"), do: "btn-error"
  defp variant_class("success"), do: "btn-success"
  defp variant_class("warning"), do: "btn-warning"
  defp variant_class("info"), do: "btn-info"
  defp variant_class(_), do: nil

  defp size_class("xs"), do: "btn-xs"
  defp size_class("sm"), do: "btn-sm"
  defp size_class("lg"), do: "btn-lg"
  defp size_class(_), do: nil

  defp icon_size_class("xs"), do: "w-3 h-3"
  defp icon_size_class("sm"), do: "w-4 h-4"
  defp icon_size_class("lg"), do: "w-6 h-6"
  defp icon_size_class(_), do: "w-5 h-5"
end
