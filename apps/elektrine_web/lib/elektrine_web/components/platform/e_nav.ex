defmodule ElektrineWeb.Components.Platform.ENav do
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

    ~H"""
    <nav aria-label="Primary modes" class={["sticky top-14 z-40 -mx-4 sm:-mx-6 lg:-mx-8", @class]}>
      <div class="mx-auto w-full max-w-7xl px-4 sm:px-6 lg:px-8">
        <div class="card border border-base-300 bg-base-100 shadow-sm rounded-lg">
          <div class="card-body px-2 py-2 sm:px-3 space-y-2">
            <div class="overflow-x-auto">
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

            <%= if @secondary_items != [] do %>
              <div class="overflow-x-auto border-t border-base-300/80 pt-2">
                <div class="flex min-w-max items-center gap-1 sm:gap-2">
                  <div class="hidden pr-2 text-[11px] font-medium uppercase tracking-[0.18em] text-base-content/45 lg:block">
                    Account
                  </div>

                  <%= for item <- @secondary_items do %>
                    <.link
                      href={item.href}
                      aria-current={if @active_tab == item.id, do: "page", else: "false"}
                      class={secondary_tab_class(@active_tab, item.id)}
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
            <% end %>
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
        platform_module: nil,
        icon: "hero-squares-2x2",
        active_icon: "hero-squares-2x2-solid"
      },
      %{
        id: "search",
        label: gettext("Search"),
        href: ~p"/search",
        platform_module: nil,
        icon: "hero-magnifying-glass",
        active_icon: "hero-magnifying-glass"
      },
      %{
        id: "chat",
        label: gettext("Chat"),
        href: ~p"/chat",
        platform_module: :chat,
        icon: "hero-chat-bubble-left-right",
        active_icon: "hero-chat-bubble-left-right-solid"
      },
      %{
        id: "timeline",
        label: gettext("Timeline"),
        href: ~p"/timeline",
        platform_module: :social,
        icon: "hero-rectangle-stack",
        active_icon: "hero-rectangle-stack-solid"
      },
      %{
        id: "discussions",
        label: gettext("Communities"),
        href: ~p"/communities",
        platform_module: :social,
        icon: "hero-chat-bubble-bottom-center-text",
        active_icon: "hero-chat-bubble-bottom-center-text-solid"
      },
      %{
        id: "gallery",
        label: gettext("Gallery"),
        href: ~p"/gallery",
        platform_module: :social,
        icon: "hero-photo",
        active_icon: "hero-photo-solid"
      },
      %{
        id: "lists",
        label: gettext("Lists"),
        href: ~p"/lists",
        platform_module: :social,
        icon: "hero-queue-list",
        active_icon: "hero-queue-list-solid"
      },
      %{
        id: "friends",
        label: gettext("Friends"),
        href: ~p"/friends",
        platform_module: :chat,
        icon: "hero-user-group",
        active_icon: "hero-user-group-solid"
      },
      %{
        id: "email",
        label: gettext("Email"),
        href: ~p"/email",
        platform_module: :email,
        icon: "hero-envelope",
        active_icon: "hero-envelope-solid"
      },
      %{
        id: "password_manager",
        label: gettext("Vault"),
        href: ~p"/account/password-manager",
        platform_module: :vault,
        icon: "hero-key",
        active_icon: "hero-key-solid"
      },
      %{
        id: "vpn",
        label: gettext("VPN"),
        href: ~p"/vpn",
        platform_module: :vpn,
        icon: "hero-shield-check",
        active_icon: "hero-shield-check-solid"
      }
    ]
    |> Enum.filter(&module_visible?/1)
  end

  defp secondary_items(nil), do: []

  defp secondary_items(_current_user) do
    [
      %{
        id: "account",
        label: gettext("Account"),
        href: ~p"/account",
        icon: "hero-cog-6-tooth",
        active_icon: "hero-cog-6-tooth-solid"
      },
      %{
        id: "profile",
        label: gettext("Profile"),
        href: ~p"/account/profile/edit",
        icon: "hero-user-circle",
        active_icon: "hero-user-circle-solid"
      },
      %{
        id: "profile-analytics",
        label: gettext("Analytics"),
        href: ~p"/account/profile/analytics",
        icon: "hero-chart-bar",
        active_icon: "hero-chart-bar-solid"
      },
      %{
        id: "profile-domains",
        label: gettext("Domains"),
        href: ~p"/account/profile/domains",
        icon: "hero-globe-alt",
        active_icon: "hero-globe-alt-solid"
      },
      %{
        id: "storage",
        label: gettext("Storage"),
        href: ~p"/account/storage",
        icon: "hero-circle-stack",
        active_icon: "hero-circle-stack-solid"
      }
    ]
  end

  defp module_visible?(%{platform_module: nil}), do: true
  defp module_visible?(%{platform_module: module}), do: Modules.enabled?(module)

  defp tab_class(active_tab, tab_id) do
    [
      "group flex items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium whitespace-nowrap transition-colors",
      if(active_tab == tab_id,
        do: "bg-base-200 text-base-content",
        else: "text-base-content/70 hover:bg-base-200/80 hover:text-base-content"
      )
    ]
  end

  defp secondary_tab_class(active_tab, tab_id) do
    [
      "group flex items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium whitespace-nowrap transition-colors",
      if(active_tab == tab_id,
        do: "bg-primary/10 text-base-content",
        else: "text-base-content/65 hover:bg-base-200/80 hover:text-base-content"
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
