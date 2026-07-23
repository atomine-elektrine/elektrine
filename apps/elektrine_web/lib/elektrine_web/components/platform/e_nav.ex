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
  attr :class, :string, default: "mb-4"
  attr :current_user, :any, default: nil
  attr :badge_counts, :map, default: nil

  def e_nav(assigns) do
    assigns =
      assigns
      |> assign_new(:class, fn -> "mb-4" end)
      |> assign_new(:current_user, fn -> nil end)
      |> assign_new(:badge_counts, fn -> nil end)

    badge_counts =
      assigns.badge_counts || PlatformENav.notification_badge_counts(assigns.current_user)

    assigns =
      assigns
      |> assign(:items, nav_items(assigns.current_user, badge_counts))
      |> assign(:secondary_items, secondary_items(assigns.current_user, badge_counts))

    ENavComponent.render(assigns)
  end

  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :header_class, :string, default: nil
  slot :actions

  def product_header(assigns) do
    ~H"""
    <div class={[
      "product-page-header flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between",
      @header_class
    ]}>
      <div class="min-w-0">
        <h1 class="mt-0.5 text-xl font-semibold tracking-tight text-base-content sm:text-2xl">
          {@title}
        </h1>
        <p :if={@description} class="mt-1 max-w-2xl text-sm leading-5 text-base-content/60">
          {@description}
        </p>
      </div>

      <div :if={@actions != []} class="flex shrink-0 flex-wrap gap-2 sm:justify-end">
        {render_slot(@actions)}
      </div>
    </div>
    """
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
