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
  attr :class, :string, default: "mb-4"

  def z_nav(assigns) do
    assigns = assign(assigns, :items, nav_items())

    ~H"""
    <nav aria-label="Primary modes" class={["sticky top-16 z-40 -mx-4 sm:-mx-6 lg:-mx-8", @class]}>
      <div class="mx-auto w-full max-w-7xl px-4 sm:px-6 lg:px-8">
        <div class="rounded-2xl border border-base-300 bg-base-100/95 shadow-sm backdrop-blur-sm">
          <div class="overflow-x-auto px-2 py-2 sm:px-3">
            <div class="flex min-w-max items-center gap-1 sm:gap-2">
              <div class="hidden pr-2 text-[11px] font-medium uppercase tracking-[0.18em] text-base-content/45 lg:block">
                Modes
              </div>

              <%= for item <- @items do %>
                <.link
                  href={item.href}
                  aria-current={if @active_tab == item.id, do: "page", else: "false"}
                  class={tab_class(@active_tab, item.id)}
                  title={item.label}
                >
                  <.icon
                    name={if @active_tab == item.id, do: item.active_icon, else: item.icon}
                    class={icon_class(@active_tab, item.id)}
                  />
                  <span class="hidden min-w-0 truncate sm:block">{item.label}</span>
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
        icon: "hero-squares-2x2",
        active_icon: "hero-squares-2x2-solid"
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
      "group flex items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium whitespace-nowrap transition-colors",
      if(active_tab == tab_id,
        do: "bg-base-200 text-base-content",
        else: "text-base-content/70 hover:bg-base-200/80 hover:text-base-content"
      )
    ]
  end

  defp icon_class(active_tab, tab_id) do
    [
      "h-4 w-4 shrink-0 transition-colors",
      if(active_tab == tab_id,
        do: "text-primary",
        else: "text-base-content/60 group-hover:text-base-content/85"
      )
    ]
  end
end
