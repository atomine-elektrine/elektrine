defmodule ElektrineNerveWeb.Components.Platform.ENav do
  @moduledoc """
  Password manager-owned wrapper for the shared platform navigation renderer.
  """

  use Phoenix.Component
  use Gettext, backend: ElektrineWeb.Gettext

  alias Elektrine.Platform.ENav, as: PlatformENav
  alias Elektrine.Platform.ENavComponent
  alias Elektrine.Platform.Modules

  attr :active_tab, :string, required: true
  attr :class, :string, default: "mb-6"
  attr :current_user, :any, default: nil

  def e_nav(assigns) do
    badge_counts = PlatformENav.notification_badge_counts(assigns.current_user)

    assigns =
      assigns
      |> assign(:items, nav_items(badge_counts))
      |> assign(:secondary_items, secondary_items(assigns.current_user, badge_counts))

    ENavComponent.render(assigns)
  end

  defp nav_items(badge_counts) do
    PlatformENav.primary_items()
    |> Enum.map(
      &Map.update!(&1, :label, fn label -> Gettext.gettext(ElektrineWeb.Gettext, label) end)
    )
    |> Enum.filter(&module_visible?/1)
    |> PlatformENav.with_badge_counts(badge_counts)
  end

  defp secondary_items(nil, _badge_counts), do: []

  defp secondary_items(_current_user, badge_counts) do
    PlatformENav.secondary_items()
    |> Enum.map(
      &Map.update!(&1, :label, fn label -> Gettext.gettext(ElektrineWeb.Gettext, label) end)
    )
    |> Enum.filter(&module_visible?/1)
    |> PlatformENav.with_badge_counts(badge_counts)
  end

  defp module_visible?(%{platform_module: nil}), do: true
  defp module_visible?(%{platform_module: module}), do: Modules.enabled?(module)
  defp module_visible?(_item), do: true
end
