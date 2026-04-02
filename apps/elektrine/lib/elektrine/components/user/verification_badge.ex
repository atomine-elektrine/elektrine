defmodule Elektrine.Components.User.VerificationBadge do
  @moduledoc false
  use Phoenix.Component

  alias Elektrine.Profiles.UserProfile
  alias Elektrine.Theme

  attr :color, :string, default: UserProfile.default(:tick_color)
  attr :size, :string, default: "md"
  attr :class, :string, default: ""
  attr :tooltip, :string, default: "Verified"

  def verification_badge(assigns) do
    size_class =
      case assigns.size do
        "sm" -> "w-4 h-4"
        "md" -> "w-5 h-5"
        "lg" -> "w-6 h-6"
        "xl" -> "w-7 h-7"
        _ -> "w-5 h-5"
      end

    assigns = assign(assigns, :size_class, size_class)

    ~H"""
    <span class="inline-flex items-center relative">
      <svg
        class={[@size_class, @class, "inline-block group"]}
        viewBox="0 0 24 24"
        aria-label={@tooltip}
        role="img"
      >
        <defs>
          <linearGradient id="verified-gradient" x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" style={"stop-color:#{@color};stop-opacity:1"} />
            <stop offset="100%" style={"stop-color:#{darken_verify_color(@color)};stop-opacity:1"} />
          </linearGradient>
        </defs>
        <g>
          <path
            fill="url(#verified-gradient)"
            d="M22.25 12c0-1.43-.88-2.67-2.19-3.34.46-1.39.2-2.9-.81-3.91s-2.52-1.27-3.91-.81c-.66-1.31-1.91-2.19-3.34-2.19s-2.67.88-3.33 2.19c-1.4-.46-2.91-.2-3.92.81s-1.26 2.52-.8 3.91c-1.31.67-2.2 1.91-2.2 3.34s.89 2.67 2.2 3.34c-.46 1.39-.21 2.9.8 3.91s2.52 1.26 3.91.81c.67 1.31 1.91 2.19 3.34 2.19s2.68-.88 3.34-2.19c1.39.46 2.9.2 3.91-.81s1.27-2.52.81-3.91c1.31-.67 2.19-1.91 2.19-3.34zm-11.71 4.2L6.8 12.46l1.41-1.42 2.26 2.26 4.8-5.23 1.47 1.36-6.2 6.77z"
          />
          <path
            fill={Theme.rgba(Theme.inverse_text_color(), 0.2)}
            d="M22.25 12c0-1.43-.88-2.67-2.19-3.34.46-1.39.2-2.9-.81-3.91s-2.52-1.27-3.91-.81c-.66-1.31-1.91-2.19-3.34-2.19s-2.67.88-3.33 2.19c-1.4-.46-2.91-.2-3.92.81s-1.26 2.52-.8 3.91c-1.31.67-2.2 1.91-2.2 3.34s.89 2.67 2.2 3.34c-.46 1.39-.21 2.9.8 3.91s2.52 1.26 3.91.81c.67 1.31 1.91 2.19 3.34 2.19s2.68-.88 3.34-2.19c1.39.46 2.9.2 3.91-.81s1.27-2.52.81-3.91c1.31-.67 2.19-1.91 2.19-3.34zm-11.71 4.2L6.8 12.46l1.41-1.42 2.26 2.26 4.8-5.23 1.47 1.36-6.2 6.77z"
          />
        </g>
        <title>{@tooltip}</title>
      </svg>
    </span>
    """
  end

  defp darken_verify_color(hex), do: Theme.darken(hex, 0.25)
end
