defmodule ElektrineDNSWeb.Components.Platform.ENav do
  @moduledoc """
  DNS-owned wrapper for the shared platform navigation renderer.
  """

  use Phoenix.Component
  use Gettext, backend: ElektrineWeb.Gettext

  alias Elektrine.Platform.ENav, as: PlatformENav
  alias Elektrine.Platform.ENavComponent

  attr :active_tab, :string, required: true
  attr :class, :string, default: "mb-6"
  attr :current_user, :any, default: nil

  def e_nav(assigns) do
    badge_counts = PlatformENav.notification_badge_counts(assigns.current_user)

    assigns =
      assigns
      |> assign(:items, nav_items(assigns.current_user, badge_counts))
      |> assign(:secondary_items, secondary_items(assigns.current_user, badge_counts))

    ENavComponent.render(assigns)
  end

  defp nav_items(current_user, badge_counts) do
    PlatformENav.primary_items()
    |> Enum.map(
      &Map.update!(&1, :label, fn label -> Gettext.gettext(ElektrineWeb.Gettext, label) end)
    )
    |> Enum.filter(&PlatformENav.visible?(&1, current_user))
    |> PlatformENav.with_badge_counts(badge_counts)
  end

  defp secondary_items(nil, _badge_counts), do: []

  defp secondary_items(current_user, badge_counts) do
    PlatformENav.secondary_items()
    |> Enum.map(
      &Map.update!(&1, :label, fn label -> Gettext.gettext(ElektrineWeb.Gettext, label) end)
    )
    |> Enum.filter(&PlatformENav.visible?(&1, current_user))
    |> PlatformENav.with_badge_counts(badge_counts)
  end
end
