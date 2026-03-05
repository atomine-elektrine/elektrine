defmodule ElektrineWeb.Components.Platform.ZNav do
  @moduledoc """
  Provides unified product navigation components.
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
  Renders the unified product navigation tabs.

  ## Examples

      <.z_nav active_tab="chat" />
      <.z_nav active_tab="timeline" />
      <.z_nav active_tab="discussions" />

  """
  attr :active_tab, :string, required: true
  attr :class, :string, default: "mb-6"

  def z_nav(assigns) do
    assigns = assign(assigns, :items, nav_items())

    ~H"""
    <nav class={["sticky top-16 z-40 -mx-4 sm:-mx-6 lg:-mx-8", @class]}>
      <div class="mx-auto w-full max-w-7xl px-4 sm:px-6 lg:px-8">
        <div class="rounded-box border border-base-300 bg-base-100/90 backdrop-blur-sm shadow-sm">
          <div class="overflow-x-auto px-2 py-2 sm:px-3 lg:overflow-x-visible">
            <div class="mx-auto flex min-w-max items-center justify-center gap-1 lg:grid lg:w-full lg:min-w-0 lg:grid-flow-col lg:auto-cols-fr">
              <%= for item <- @items do %>
                <.link href={item.href} class={tab_class(@active_tab, item.id)}>
                  <.icon
                    name={if @active_tab == item.id, do: item.active_icon, else: item.icon}
                    class="h-4 w-4 shrink-0 lg:h-3.5 lg:w-3.5 xl:h-4 xl:w-4"
                  />
                  <span class="hidden min-w-0 sm:block lg:flex-1 lg:text-center lg:text-[11px] xl:text-sm">
                    {item.label}
                  </span>
                </.link>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </nav>
    """
  end

  defp nav_items do
    [
      %{
        id: "overview",
        label: gettext("Overview"),
        href: ~p"/overview",
        icon: "hero-sparkles",
        active_icon: "hero-sparkles-solid"
      },
      %{
        id: "search",
        label: gettext("Search"),
        href: ~p"/search",
        icon: "hero-magnifying-glass",
        active_icon: "hero-magnifying-glass"
      },
      %{
        id: "chat",
        label: gettext("Chat"),
        href: ~p"/chat",
        icon: "hero-chat-bubble-left-right",
        active_icon: "hero-chat-bubble-left-right-solid"
      },
      %{
        id: "timeline",
        label: gettext("Timeline"),
        href: ~p"/timeline",
        icon: "hero-rectangle-stack",
        active_icon: "hero-rectangle-stack-solid"
      },
      %{
        id: "discussions",
        label: gettext("Communities"),
        href: ~p"/communities",
        icon: "hero-chat-bubble-bottom-center-text",
        active_icon: "hero-chat-bubble-bottom-center-text-solid"
      },
      %{
        id: "gallery",
        label: gettext("Gallery"),
        href: ~p"/gallery",
        icon: "hero-photo",
        active_icon: "hero-photo-solid"
      },
      %{
        id: "lists",
        label: gettext("Lists"),
        href: ~p"/lists",
        icon: "hero-queue-list",
        active_icon: "hero-queue-list-solid"
      },
      %{
        id: "friends",
        label: gettext("Friends"),
        href: ~p"/friends",
        icon: "hero-user-group",
        active_icon: "hero-user-group-solid"
      },
      %{
        id: "email",
        label: gettext("Email"),
        href: ~p"/email",
        icon: "hero-envelope",
        active_icon: "hero-envelope-solid"
      },
      %{
        id: "password_manager",
        label: gettext("Vault"),
        href: ~p"/account/password-manager",
        icon: "hero-key",
        active_icon: "hero-key-solid"
      },
      %{
        id: "vpn",
        label: gettext("VPN"),
        href: ~p"/vpn",
        icon: "hero-shield-check",
        active_icon: "hero-shield-check-solid"
      }
    ]
  end

  defp tab_class(active_tab, tab_id) do
    [
      "flex min-w-0 items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm whitespace-nowrap transition-colors lg:gap-0.5 lg:justify-center lg:overflow-hidden lg:px-1 xl:gap-1 xl:px-2",
      if(active_tab == tab_id,
        do: "bg-base-200 text-base-content font-medium",
        else: "text-base-content/75 hover:bg-base-200 hover:text-base-content"
      )
    ]
  end
end
