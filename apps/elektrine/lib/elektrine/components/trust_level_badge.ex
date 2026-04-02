defmodule Elektrine.Components.TrustLevelBadge do
  @moduledoc """
  Trust level badge component for displaying user trust levels.
  """
  use Phoenix.Component

  alias Elektrine.Theme

  attr :level, :integer, required: true
  attr :show_name, :boolean, default: false
  attr :size, :string, default: "md"
  attr :class, :string, default: ""

  def trust_level_badge(assigns) do
    level_info = Elektrine.Accounts.TrustLevel.get_level_info(assigns.level)

    size_class =
      case assigns.size do
        "sm" -> "w-4 h-4"
        "md" -> "w-5 h-5"
        "lg" -> "w-6 h-6"
        "xl" -> "w-7 h-7"
        _ -> "w-5 h-5"
      end

    color =
      case assigns.level do
        0 -> Theme.default_value("color_base_content")
        1 -> Theme.default_value("color_info")
        2 -> Theme.default_value("color_success")
        3 -> Theme.default_value("color_accent")
        4 -> Theme.default_value("color_error")
        _ -> Theme.default_value("color_base_content")
      end

    unique_id = "tl-gradient-#{assigns.level}-#{:erlang.unique_integer([:positive])}"

    assigns =
      assigns
      |> assign(:level_info, level_info)
      |> assign(:size_class, size_class)
      |> assign(:color, color)
      |> assign(:unique_id, unique_id)

    ~H"""
    <span class="inline-flex items-center relative">
      <svg
        class={[@size_class, @class, "inline-block group"]}
        viewBox="0 0 24 24"
        aria-label={@level_info.description}
        role="img"
      >
        <title>TL{@level} - {@level_info.name}</title>
        <defs>
          <linearGradient id={@unique_id} x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" style={"stop-color:#{@color};stop-opacity:1"} />
            <stop offset="100%" style={"stop-color:#{darken_color(@color)};stop-opacity:1"} />
          </linearGradient>
          <mask id={"mask-#{@unique_id}"}>
            <path
              fill={Theme.inverse_text_color()}
              d="M22.25 12c0-1.43-.88-2.67-2.19-3.34.46-1.39.2-2.9-.81-3.91s-2.52-1.27-3.91-.81c-.66-1.31-1.91-2.19-3.34-2.19s-2.67.88-3.33 2.19c-1.4-.46-2.91-.2-3.92.81s-1.26 2.52-.8 3.91c-1.31.67-2.2 1.91-2.2 3.34s.89 2.67 2.2 3.34c-.46 1.39-.21 2.9.8 3.91s2.52 1.26 3.91.81c.67 1.31 1.91 2.19 3.34 2.19s2.68-.88 3.34-2.19c1.39.46 2.9.2 3.91-.81s1.27-2.52.81-3.91c1.31-.67 2.19-1.91 2.19-3.34z"
            />
            <text
              x="12"
              y="15.5"
              text-anchor="middle"
              fill={Theme.dark_text_color()}
              font-size="11"
              font-weight="bold"
              font-family="system-ui"
            >
              {@level}
            </text>
          </mask>
        </defs>
        <g>
          <path
            fill={"url(##{@unique_id})"}
            mask={"url(#mask-#{@unique_id})"}
            d="M22.25 12c0-1.43-.88-2.67-2.19-3.34.46-1.39.2-2.9-.81-3.91s-2.52-1.27-3.91-.81c-.66-1.31-1.91-2.19-3.34-2.19s-2.67.88-3.33 2.19c-1.4-.46-2.91-.2-3.92.81s-1.26 2.52-.8 3.91c-1.31.67-2.0 1.91-2.2 3.34s.89 2.67 2.2 3.34c-.46 1.39-.21 2.9.8 3.91s2.52 1.26 3.91.81c.67 1.31 1.91 2.19 3.34 2.19s2.68-.88 3.34-2.19c1.39.46 2.9.2 3.91-.81s1.27-2.52.81-3.91c1.31-.67 2.19-1.91 2.19-3.34z"
          />
          <path
            fill={Theme.rgba(Theme.inverse_text_color(), 0.15)}
            mask={"url(#mask-#{@unique_id})"}
            d="M22.25 12c0-1.43-.88-2.67-2.19-3.34.46-1.39.2-2.9-.81-3.91s-2.52-1.27-3.91-.81c-.66-1.31-1.91-2.19-3.34-2.19s-2.67.88-3.33 2.19c-1.4-.46-2.91-.2-3.92.81s-1.26 2.52-.8 3.91c-1.31.67-2.2 1.91-2.2 3.34s.89 2.67 2.2 3.34c-.46 1.39-.21 2.9.8 3.91s2.52 1.26 3.91.81c.67 1.31 1.91 2.19 3.34 2.19s2.68-.88 3.34-2.19c1.39.46 2.9.2 3.91-.81s1.27-2.52.81-3.91c1.31-.67 2.19-1.91 2.19-3.34z"
          />
        </g>
      </svg>
      <%= if @show_name do %>
        <span class="ml-1 text-xs font-medium text-base-content/80">{@level_info.name}</span>
      <% end %>
    </span>
    """
  end

  defp darken_color(hex), do: Theme.darken(hex, 0.25)
end
