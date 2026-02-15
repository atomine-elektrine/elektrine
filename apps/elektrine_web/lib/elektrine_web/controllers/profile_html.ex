defmodule ElektrineWeb.ProfileHTML do
  @moduledoc """
  Templates for profile pages rendered by ProfileController.

  This module provides helpers for rendering static profile pages that work
  correctly on both the main domain and subdomains (e.g., username.z.org).

  Note: Uses `profile_url/2` from HtmlHelpers to build absolute URLs that
  ensure navigation goes to the main domain when accessed via subdomains.
  """

  use ElektrineWeb, :html

  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Components.Profile.Containers
  import ElektrineWeb.Components.User.VerificationBadge
  import ElektrineWeb.HtmlHelpers

  embed_templates "../live/profile_live/show.*"

  defp hex_to_rgb("#" <> hex) do
    {r, _} = Integer.parse(String.slice(hex, 0, 2), 16)
    {g, _} = Integer.parse(String.slice(hex, 2, 2), 16)
    {b, _} = Integer.parse(String.slice(hex, 4, 2), 16)
    {r, g, b}
  end

  defp hex_to_rgb(_hex), do: {0, 0, 0}

  defp lighten_color(hex, factor) do
    {r, g, b} = hex_to_rgb(hex)
    new_r = min(255, round(r + (255 - r) * factor))
    new_g = min(255, round(g + (255 - g) * factor))
    new_b = min(255, round(b + (255 - b) * factor))

    "#" <>
      String.pad_leading(Integer.to_string(new_r, 16), 2, "0") <>
      String.pad_leading(Integer.to_string(new_g, 16), 2, "0") <>
      String.pad_leading(Integer.to_string(new_b, 16), 2, "0")
  end

  defp is_light_color(hex) do
    {r, g, b} = hex_to_rgb(hex)
    luminance = 0.2126 * (r / 255) + 0.7152 * (g / 255) + 0.0722 * (b / 255)
    luminance > 0.5
  end
end
