defmodule ElektrineWeb.ProfileTheme do
  @moduledoc false

  alias Elektrine.Profiles.UserProfile
  alias Elektrine.Theme
  alias Elektrine.Uploads

  def profile_color(profile, field) when is_atom(field) do
    case profile do
      %{^field => value} when is_binary(value) and value != "" -> value
      _ -> UserProfile.default(field)
    end
  end

  def profile_css_color(_profile, :accent_color, true), do: "var(--color-primary)"
  def profile_css_color(_profile, :text_color, true), do: "var(--color-base-content)"
  def profile_css_color(_profile, :background_color, true), do: "var(--color-base-100)"
  def profile_css_color(profile, field, _), do: profile_color(profile, field)

  def profile_hex_fallback(:accent_color), do: Theme.default_value("color_primary")
  def profile_hex_fallback(:text_color), do: Theme.default_value("color_base_content")
  def profile_hex_fallback(:background_color), do: Theme.default_value("color_base_100")

  def profile_hex_fallback(field) do
    UserProfile.default(field)
  end

  def button_text_color(_profile, true), do: "var(--color-primary-content)"

  def button_text_color(profile, false) do
    profile
    |> profile_color(:accent_color)
    |> Theme.contrast_text()
  end

  def presence_status_class("online"), do: "bg-success"
  def presence_status_class("idle"), do: "bg-warning"
  def presence_status_class("away"), do: "bg-warning"
  def presence_status_class("dnd"), do: "bg-error"
  def presence_status_class(_), do: "bg-base-content/40"

  def border_overlay_color(profile, is_default_profile, opacity \\ 0.3) do
    color = profile_css_color(profile, :accent_color, is_default_profile)
    "color-mix(in srgb, #{color} #{round(opacity * 100)}%, transparent)"
  end

  def profile_page_style(profile, true) do
    [
      default_profile_background_style(),
      profile_font_style(profile),
      profile_cursor_style(profile)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def profile_page_style(profile, false) do
    [
      custom_profile_background_style(profile),
      profile_font_style(profile),
      profile_cursor_style(profile)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def profile_container_style(_profile, true), do: "z-index: 10; position: relative;"

  def profile_container_style(nil, false), do: "z-index: 10; position: relative;"

  def profile_container_style(profile, false) do
    opacity = profile.profile_opacity || 1.0
    blur = profile.profile_blur || 0

    container_color =
      profile.container_background_color || profile_color(profile, :background_color)

    container_opacity = profile.container_opacity || 0.4

    adjusted_opacity =
      if profile.container_pattern && profile.container_pattern != "none" do
        container_opacity * 0.7
      else
        container_opacity
      end

    blur_style =
      if blur > 0 do
        "backdrop-filter: blur(#{blur}px); -webkit-backdrop-filter: blur(#{blur}px);"
      else
        ""
      end

    "opacity: #{opacity}; z-index: 10; position: relative; background-color: #{Theme.rgba(container_color, adjusted_opacity)}; #{blur_style}"
  end

  def timeline_blade_style(_profile, true) do
    "z-index: 5; background: #{default_profile_panel_gradient()}; border-left: 1px solid #{default_profile_panel_border()};"
  end

  def timeline_blade_style(profile, false) do
    container_color =
      (profile && profile.container_background_color) || profile_color(profile, :background_color)

    container_opacity = (profile && profile.container_opacity) || 0.4

    "z-index: 5; background-color: #{Theme.rgba(container_color, container_opacity)};"
  end

  def mobile_timeline_style(_profile, true) do
    "--profile-text: var(--color-base-content); --profile-accent: var(--color-primary); background: #{default_profile_panel_gradient()}; border-top: 1px solid #{default_profile_panel_border()};"
  end

  def mobile_timeline_style(profile, false) do
    container_color =
      (profile && profile.container_background_color) || profile_color(profile, :background_color)

    container_opacity = (profile && profile.container_opacity) || 0.4

    "--profile-text: #{profile_color(profile, :text_color)}; --profile-accent: #{profile_color(profile, :accent_color)}; background-color: #{Theme.rgba(container_color, container_opacity)};"
  end

  defp custom_profile_background_style(%{background_url: url, background_type: "video"} = profile)
       when is_binary(url) and url != "" do
    "background-color: #{profile_color(profile, :background_color)};"
  end

  defp custom_profile_background_style(%{background_url: url, background_type: "image"} = profile)
       when is_binary(url) and url != "" do
    x = profile_percent(profile, :background_focal_x, 50)
    y = profile_percent(profile, :background_focal_y, 50)

    "background-image: url(#{Uploads.background_url(url)}); background-size: cover; background-position: #{x}% #{y}%; background-repeat: no-repeat; background-attachment: fixed;"
  end

  defp custom_profile_background_style(%{background_type: "solid", background_color: color})
       when is_binary(color) and color != "" do
    "background-color: #{color};"
  end

  defp custom_profile_background_style(%{background_type: "gradient"}) do
    custom_profile_gradient_style()
  end

  defp custom_profile_background_style(%{background_color: color})
       when is_binary(color) and color != "" do
    "background-color: #{color};"
  end

  defp custom_profile_background_style(_profile), do: custom_profile_gradient_style()

  defp profile_font_style(%{font_family: font_family})
       when is_binary(font_family) and font_family != "" do
    "font-family: '#{font_family}', sans-serif;"
  end

  defp profile_font_style(_profile), do: ""

  defp profile_cursor_style(%{cursor_style: cursor_style})
       when is_binary(cursor_style) and cursor_style != "" and cursor_style != "default" do
    "cursor: #{cursor_style};"
  end

  defp profile_cursor_style(_profile), do: ""

  defp default_profile_background_style do
    "background: linear-gradient(180deg, color-mix(in srgb, var(--color-base-100) 98%, transparent) 0%, color-mix(in srgb, var(--color-base-200) 94%, transparent) 100%);"
  end

  defp default_profile_panel_gradient do
    "linear-gradient(145deg, color-mix(in srgb, var(--color-base-100) 95%, transparent), color-mix(in srgb, var(--color-base-200) 90%, transparent))"
  end

  defp default_profile_panel_border do
    "color-mix(in srgb, var(--color-base-content) 14%, transparent)"
  end

  defp custom_profile_gradient_style do
    "background: linear-gradient(135deg, color-mix(in srgb, var(--profile-bg) 78%, var(--color-base-100) 22%) 0%, color-mix(in srgb, var(--profile-bg) 68%, var(--color-base-100) 32%) 25%, color-mix(in srgb, var(--profile-bg) 58%, var(--color-base-100) 42%) 50%, color-mix(in srgb, var(--profile-bg) 66%, var(--color-base-100) 34%) 75%, color-mix(in srgb, var(--profile-bg) 82%, var(--color-base-100) 18%) 100%);"
  end

  defp profile_percent(profile, field, fallback) do
    value = Map.get(profile || %{}, field, fallback)

    value
    |> case do
      number when is_integer(number) or is_float(number) -> number
      _ -> fallback
    end
    |> max(0)
    |> min(100)
  end
end
