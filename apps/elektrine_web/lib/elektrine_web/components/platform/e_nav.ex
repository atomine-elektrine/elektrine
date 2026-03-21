defmodule ElektrineWeb.Components.Platform.ENav do
  @moduledoc """
  Provides unified product navigation components.
  """
  use Phoenix.Component
  use Gettext, backend: ElektrineWeb.Gettext

  # Routes generation with the ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router,
    statics: ElektrineWeb.static_paths()

  alias Elektrine.Platform.Modules
  alias Elektrine.Platform.ENav, as: PlatformENav
  alias Elektrine.Platform.ENavComponent

  @doc """
  Renders the unified product navigation tabs.

  ## Examples

      <.e_nav active_tab="chat" />
      <.e_nav active_tab="timeline" />
      <.e_nav active_tab="discussions" />

  """
  attr :active_tab, :string, required: true
  attr :class, :string, default: "mb-6"
  attr :current_user, :any, default: nil

  def z_nav(assigns), do: e_nav(assigns)

  def e_nav(assigns) do
    assigns =
      assigns
      |> assign_new(:class, fn -> "mb-6" end)
      |> assign_new(:current_user, fn -> nil end)

    assigns =
      assigns
      |> assign(:items, nav_items())
      |> assign(:secondary_items, secondary_items(assigns.current_user))

    ENavComponent.render(assigns)
  end

  defp nav_items do
    PlatformENav.primary_items()
    |> Enum.map(
      &Map.update!(&1, :label, fn label -> Gettext.gettext(ElektrineWeb.Gettext, label) end)
    )
    |> Enum.filter(&module_visible?/1)
  end

  defp secondary_items(nil), do: []

  defp secondary_items(_current_user) do
    PlatformENav.secondary_items()
    |> Enum.map(
      &Map.update!(&1, :label, fn label -> Gettext.gettext(ElektrineWeb.Gettext, label) end)
    )
  end

  defp module_visible?(%{platform_module: nil}), do: true
  defp module_visible?(%{platform_module: module}), do: Modules.enabled?(module)
end
