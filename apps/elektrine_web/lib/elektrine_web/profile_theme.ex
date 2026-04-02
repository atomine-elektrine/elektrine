defmodule ElektrineWeb.ProfileTheme do
  @moduledoc false

  alias Elektrine.Profiles.UserProfile
  alias Elektrine.Theme

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
end
