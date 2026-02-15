defmodule ElektrineWeb.Components.Platform.ElektrineNav do
  @moduledoc """
  Provides Elektrine platform-specific UI components.

  Components for the email platform including navigation, mailbox UI, etc.
  """
  use Phoenix.Component
  use Gettext, backend: ElektrineWeb.Gettext

  import ElektrineWeb.CoreComponents

  # Routes generation with the ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router,
    statics: ElektrineWeb.static_paths()

  @doc """
  Renders the Elektrine platform navigation tabs.

  ## Examples

      <.elektrine_nav active_tab="email" />

  """
  attr :active_tab, :string, default: "email"

  def elektrine_nav(assigns) do
    ~H"""
    <div class="sticky top-16 z-40 card shadow-lg rounded-box border border-purple-500/30 mb-6 py-2 px-2 sm:px-4 bg-base-100/80 backdrop-blur-md">
      <div class="flex items-center gap-2 sm:gap-4">
        <div class="flex flex-1 overflow-x-auto gap-1">
          <.link
            href={~p"/email"}
            class={[
              "flex items-center px-3 py-1.5 rounded-lg text-sm transition-colors whitespace-nowrap",
              @active_tab == "email" && "bg-primary/15 text-primary",
              @active_tab != "email" && "hover:bg-base-200"
            ]}
          >
            <.icon
              name={if @active_tab == "email", do: "hero-envelope-solid", else: "hero-envelope"}
              class="w-4 h-4 sm:mr-2"
            />
            <span class="hidden sm:inline">{gettext("Email")}</span>
          </.link>
          <.link
            href={~p"/vpn"}
            class={[
              "flex items-center px-3 py-1.5 rounded-lg text-sm transition-colors whitespace-nowrap",
              @active_tab == "vpn" && "bg-primary/15 text-primary",
              @active_tab != "vpn" && "hover:bg-base-200"
            ]}
          >
            <.icon
              name={if @active_tab == "vpn", do: "hero-shield-check-solid", else: "hero-shield-check"}
              class="w-4 h-4 sm:mr-2"
            />
            <span class="hidden sm:inline">{gettext("VPN")}</span>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
