defmodule Elektrine.Platform.ENavComponent do
  @moduledoc false

  use Phoenix.Component

  attr :active_tab, :string, required: true
  attr :class, :string, default: "mb-4"
  attr :items, :list, required: true
  attr :secondary_items, :list, default: []

  def render(assigns) do
    secondary_active? =
      Enum.any?(assigns.secondary_items, &(&1.id == assigns.active_tab))

    secondary_badge_total =
      assigns.secondary_items
      |> Enum.map(&Map.get(&1, :badge_count, 0))
      |> Enum.filter(&is_integer/1)
      |> Enum.sum()

    assigns =
      assigns
      |> assign(:secondary_active?, secondary_active?)
      |> assign(:secondary_badge_total, secondary_badge_total)

    ~H"""
    <nav
      aria-label="Primary modes"
      class={["e-nav -mx-4 -mt-6 sm:-mx-6 lg:-mx-8", @class]}
    >
      <div class="mx-auto w-full max-w-7xl px-4 sm:px-6 lg:px-8">
        <div class="flex items-end gap-1 border-b border-base-300/70 sm:gap-1.5">
          <div class="e-nav-scroll -ml-2 min-w-0 flex-1 overflow-x-auto overscroll-x-contain pt-1 sm:-ml-2.5">
            <div class="flex w-max min-w-full items-center gap-0.5 sm:gap-1" role="list">
              <%= for item <- @items do %>
                <.link
                  href={item.href}
                  role="listitem"
                  aria-current={if @active_tab == item.id, do: "page", else: "false"}
                  aria-label={item.label}
                  class={tab_class(@active_tab, item.id)}
                  title={item.label}
                >
                  <.nav_icon
                    name={if @active_tab == item.id, do: item.active_icon, else: item.icon}
                    class={icon_class(@active_tab, item.id)}
                  />
                  <span class={label_class(@active_tab, item.id)}>{item.label}</span>
                  <.nav_badge count={Map.get(item, :badge_count, 0)} />
                </.link>
              <% end %>
            </div>
          </div>

          <%= if @secondary_items != [] do %>
            <div class="e-nav-more dropdown dropdown-end -mr-2 shrink-0 pt-1 sm:-mr-2.5">
              <div
                tabindex="0"
                role="button"
                aria-haspopup="menu"
                aria-label="More navigation"
                aria-current={if @secondary_active?, do: "true", else: "false"}
                class={more_trigger_class(@secondary_active?)}
                title="More"
              >
                <.nav_icon
                  name={
                    if @secondary_active?,
                      do: "hero-ellipsis-horizontal-solid",
                      else: "hero-ellipsis-horizontal"
                  }
                  class={more_icon_class(@secondary_active?)}
                />
                <span class="hidden min-w-0 truncate xl:inline">More</span>
                <.nav_badge count={@secondary_badge_total} />
              </div>

              <ul
                tabindex="0"
                role="menu"
                aria-label="Account and tools"
                class="e-nav-more-menu dropdown-content floating-menu menu z-40 mt-2 w-56 rounded-box border border-base-300/80 bg-base-100 p-1.5 shadow-lg"
              >
                <%= for item <- @secondary_items do %>
                  <li role="none">
                    <.link
                      href={item.href}
                      role="menuitem"
                      aria-current={if @active_tab == item.id, do: "page", else: "false"}
                      class={more_item_class(@active_tab, item.id)}
                    >
                      <.nav_icon
                        name={if @active_tab == item.id, do: item.active_icon, else: item.icon}
                        class={icon_class(@active_tab, item.id)}
                      />
                      <span class="min-w-0 flex-1 truncate">{item.label}</span>
                      <.nav_badge count={Map.get(item, :badge_count, 0)} />
                    </.link>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>
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

  attr :count, :any, default: 0

  def nav_badge(assigns) do
    ~H"""
    <span
      :if={show_badge?(@count)}
      class="absolute -right-1 -top-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-error px-1 text-[10px] font-bold leading-none text-error-content ring-2 ring-base-100"
    >
      {format_badge_count(@count)}
    </span>
    """
  end

  defp tab_class(active_tab, tab_id) do
    [
      "e-nav-link group relative flex min-h-9 min-w-9 shrink-0 items-center justify-center gap-1.5 px-2 text-sm font-medium whitespace-nowrap transition-colors sm:px-2.5",
      if(active_tab == tab_id,
        do:
          "text-base-content after:absolute after:inset-x-1.5 after:bottom-0 after:h-0.5 after:rounded-full after:bg-primary",
        else: "text-base-content/60 hover:text-base-content"
      )
    ]
  end

  defp more_trigger_class(secondary_active?) do
    [
      "e-nav-link group relative flex min-h-9 min-w-9 cursor-pointer items-center justify-center gap-1.5 px-2 text-sm font-medium whitespace-nowrap transition-colors sm:px-2.5",
      if(secondary_active?,
        do:
          "text-base-content after:absolute after:inset-x-1.5 after:bottom-0 after:h-0.5 after:rounded-full after:bg-primary",
        else: "text-base-content/60 hover:text-base-content"
      )
    ]
  end

  defp more_item_class(active_tab, tab_id) do
    [
      "e-nav-link group relative flex w-full items-center gap-2 rounded-lg px-2.5 py-2 text-sm font-medium transition-colors",
      if(active_tab == tab_id,
        do: "bg-primary/10 text-base-content",
        else: "text-base-content/80 hover:bg-base-200/80 hover:text-base-content"
      )
    ]
  end

  defp label_class(active_tab, tab_id) do
    if active_tab == tab_id do
      "min-w-0 max-w-[7rem] truncate sm:max-w-[9rem]"
    else
      # Hide inactive labels until wide desktops so mid-size screens stay
      # single-row icon-first without wrapping into a tall stack.
      "hidden min-w-0 max-w-[9rem] truncate xl:inline"
    end
  end

  defp icon_class(active_tab, tab_id) do
    [
      "h-5 w-5 shrink-0 transition-colors sm:h-4 sm:w-4",
      if(active_tab == tab_id,
        do: "text-primary",
        else: "text-base-content/60 group-hover:text-base-content/85"
      )
    ]
  end

  defp more_icon_class(secondary_active?) do
    [
      "h-5 w-5 shrink-0 transition-colors sm:h-4 sm:w-4",
      if(secondary_active?,
        do: "text-primary",
        else: "text-base-content/60 group-hover:text-base-content/85"
      )
    ]
  end

  defp show_badge?(count) when is_integer(count), do: count > 0
  defp show_badge?(_count), do: false

  defp format_badge_count(count) when is_integer(count) and count > 99, do: "99+"
  defp format_badge_count(count) when is_integer(count), do: Integer.to_string(count)
end
