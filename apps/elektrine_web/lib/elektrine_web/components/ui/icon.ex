defmodule ElektrineWeb.Components.UI.Icon do
  @moduledoc """
  Icon component for rendering Heroicons.
  """
  use Phoenix.Component

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in your `assets/tailwind.config.js`.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={["ui-icon", @name, @class]} />
    """
  end

  attr :class, :string, default: nil

  def asterism(assigns) do
    ~H"""
    <span class={@class}>
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="w-full h-full"
      >
        <path d="M12 3.5 L12 8.5 M9.8 4.8 L14.2 7.2 M9.8 7.2 L14.2 4.8" />
        <path d="M6 17 L6 22 M3.8 18.3 L8.2 20.7 M3.8 20.7 L8.2 18.3" />
        <path d="M18 17 L18 22 M15.8 18.3 L20.2 20.7 M15.8 20.7 L20.2 18.3" />
      </svg>
    </span>
    """
  end
end
