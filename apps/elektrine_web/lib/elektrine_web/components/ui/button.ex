defmodule ElektrineWeb.Components.UI.Button do
  @moduledoc """
  Button component for user interactions.

  Supports various styles, sizes, and loading states for a consistent
  button experience across the application.
  """
  use Phoenix.Component

  alias ElektrineWeb.Components.UI.Spinner

  @doc """
  Renders a button.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" class="ml-2">Send!</.button>
      <.button variant="secondary">Cancel</.button>
      <.button loading={true}>Saving...</.button>
      <.button size="lg" variant="primary">Submit</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil

  attr :variant, :string,
    default: "primary",
    values: ["primary", "secondary", "ghost", "error", "success", "warning", "info"]

  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]
  attr :loading, :boolean, default: false, doc: "Show loading spinner"
  attr :loading_text, :string, default: nil, doc: "Text to show when loading"
  attr :icon_left, :string, default: nil, doc: "Heroicon name for left icon"
  attr :icon_right, :string, default: nil, doc: "Heroicon name for right icon"
  attr :rest, :global, include: ~w(disabled form name value phx-click phx-disable-with)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "btn",
        variant_class(@variant),
        size_class(@size),
        @loading && "btn-loading pointer-events-none",
        "min-h-11 min-w-11",
        @class
      ]}
      disabled={@loading || assigns[:disabled]}
      aria-busy={@loading}
      {@rest}
    >
      <%= if @loading do %>
        <Spinner.spinner class={spinner_size_class(@size)} />
        <span>{@loading_text || render_slot(@inner_block)}</span>
      <% else %>
        <%= if @icon_left do %>
          <ElektrineWeb.Components.UI.Icon.icon name={@icon_left} class={icon_size_class(@size)} />
        <% end %>
        <span>{render_slot(@inner_block)}</span>
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

      <.icon_button icon="hero-plus" />
      <.icon_button icon="hero-trash" variant="error" />
  """
  attr :icon, :string, required: true, doc: "Heroicon name"
  attr :class, :string, default: nil
  attr :variant, :string, default: "ghost", values: ["primary", "secondary", "ghost", "error"]
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]
  attr :label, :string, default: nil, doc: "Accessibility label"
  attr :rest, :global, include: ~w(disabled phx-click)

  def icon_button(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "btn btn-circle",
        variant_class(@variant),
        icon_button_size_class(@size),
        "min-h-11 min-w-11 p-2.5 sm:p-2",
        @class
      ]}
      aria-label={@label}
      {@rest}
    >
      <ElektrineWeb.Components.UI.Icon.icon name={@icon} class={icon_size_class(@size)} />
    </button>
    """
  end

  # Private helpers

  defp variant_class("primary"), do: "btn-primary"
  defp variant_class("secondary"), do: "btn-secondary"
  defp variant_class("ghost"), do: "btn-ghost"
  defp variant_class("error"), do: "btn-error"
  defp variant_class("success"), do: "btn-success"
  defp variant_class("warning"), do: "btn-warning"
  defp variant_class("info"), do: "btn-info"
  defp variant_class(_), do: "btn-primary"

  defp size_class("xs"), do: "btn-xs"
  defp size_class("sm"), do: "btn-sm"
  defp size_class("lg"), do: "btn-lg"
  defp size_class(_), do: ""

  defp icon_button_size_class("xs"), do: "btn-xs"
  defp icon_button_size_class("sm"), do: "btn-sm"
  defp icon_button_size_class("lg"), do: "btn-lg"
  defp icon_button_size_class(_), do: ""

  defp icon_size_class("xs"), do: "w-3 h-3"
  defp icon_size_class("sm"), do: "w-4 h-4"
  defp icon_size_class("lg"), do: "w-6 h-6"
  defp icon_size_class(_), do: "w-5 h-5"

  defp spinner_size_class("xs"), do: "w-3 h-3"
  defp spinner_size_class("sm"), do: "w-4 h-4"
  defp spinner_size_class("lg"), do: "w-6 h-6"
  defp spinner_size_class(_), do: "w-5 h-5"
end
