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
  alias Elektrine.Platform.Modules

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

  attr :eyebrow, :string, default: nil
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
        <p
          :if={@eyebrow}
          class="text-[11px] font-semibold uppercase tracking-[0.16em] text-base-content/45"
        >
          {@eyebrow}
        </p>
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
