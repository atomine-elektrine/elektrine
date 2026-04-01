defmodule Elektrine.Platform.ENavComponent do
  @moduledoc false

  use Phoenix.Component

  attr :active_tab, :string, required: true
  attr :class, :string, default: "mb-6"
  attr :items, :list, required: true
  attr :secondary_items, :list, default: []

  def render(assigns) do
    ~H"""
    <nav
      aria-label="Primary modes"
      class={["e-nav sticky top-14 z-40 -mx-4 sm:-mx-6 lg:-mx-8", @class]}
    >
      <div class="mx-auto w-full max-w-7xl px-4 sm:px-6 lg:px-8">
        <div class="card panel-card rounded-lg">
          <div class="card-body px-2 py-2 sm:px-3 space-y-1">
            <div class="pt-1 pb-0.5">
              <div class="flex flex-wrap items-center gap-1 sm:gap-2">
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
                    <.nav_icon
                      name={if @active_tab == item.id, do: item.active_icon, else: item.icon}
                      class={icon_class(@active_tab, item.id)}
                    />
                    <span class="hidden min-w-0 truncate sm:block">{item.label}</span>
                  </.link>
                <% end %>
              </div>
            </div>

            <%= if @secondary_items != [] do %>
              <div class="border-t border-base-300/80 pt-2 pb-0.5">
                <div class="flex flex-wrap items-center gap-1 sm:gap-2">
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
                      <.nav_icon
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

  attr :name, :string, required: true
  attr :class, :string, default: nil

  def nav_icon(assigns) do
    ~H"""
    <span class={["ui-icon", @name, @class]} />
    """
  end

  defp tab_class(active_tab, tab_id) do
    [
      "e-nav-link group flex items-center gap-2 rounded-lg px-2.5 py-2 text-sm font-medium whitespace-nowrap transition-colors",
      if(active_tab == tab_id,
        do: "bg-primary/10 text-base-content",
        else: "text-base-content/65 hover:bg-base-200/80 hover:text-base-content"
      )
    ]
  end

  defp secondary_tab_class(active_tab, tab_id) do
    [
      "e-nav-link group flex items-center gap-2 rounded-lg px-2.5 py-2 text-sm font-medium whitespace-nowrap transition-colors",
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
