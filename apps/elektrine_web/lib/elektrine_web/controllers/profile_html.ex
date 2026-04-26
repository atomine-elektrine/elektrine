defmodule ElektrineWeb.ProfileHTML do
  @moduledoc """
  Templates for profile pages rendered by ProfileController.

  This module provides helpers for rendering static profile pages that work
  correctly on both the main domain and subdomains (e.g., username.example.com).

  Note: Uses `profile_url/2` from HtmlHelpers to build absolute URLs that
  ensure navigation goes to the main domain when accessed via subdomains.
  """

  use ElektrineWeb, :html

  import ElektrineWeb.ProfileTheme
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Components.Profile.Containers
  import ElektrineWeb.Components.Profile.Modals
  import ElektrineWeb.Components.User.VerificationBadge
  import ElektrineWeb.HtmlHelpers

  embed_templates "../live/profile_live/show.*"

  defp profile_attachment_url(attachment, context) do
    case Elektrine.Uploads.attachment_url(attachment, context) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp lighten_color(hex, factor), do: Elektrine.Theme.lighten(hex, factor)
end
