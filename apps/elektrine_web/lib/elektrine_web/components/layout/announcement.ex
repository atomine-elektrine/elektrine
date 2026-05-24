defmodule ElektrineWeb.Components.Layout.Announcement do
  @moduledoc """
  Announcement components for system-wide notifications and banners.
  """
  use Phoenix.Component

  @doc """
  Renders a system announcement banner.

  ## Examples

      <.announcement announcement={@announcement} />
      <.announcement announcement={@announcement} dismissible />

  """
  attr :announcement, :map, required: true
  attr :dismissible, :boolean, default: false
  attr :class, :string, default: nil
  attr :id, :string, default: nil

  def announcement(assigns) do
    ~H"""
    <div
      class={[
        "system-announcement flex items-start gap-3 rounded-lg px-3 py-3 text-sm sm:px-4",
        announcement_classes(@announcement.type),
        @class
      ]}
      id={@id}
    >
      <div class="system-announcement__icon mt-0.5 flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-lg">
        <.icon name={announcement_icon(@announcement.type)} class="h-4 w-4" />
      </div>

      <div class="min-w-0 flex-1 leading-5">
        <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
          <span class="font-semibold text-base-content">{@announcement.title}</span>
          <span class="text-[11px] font-semibold uppercase tracking-[0.16em] text-base-content/45">
            {announcement_label(@announcement.type)}
          </span>
        </div>

        <div class="mt-0.5 text-base-content/75">{String.trim(@announcement.content)}</div>
      </div>

      <%= if @dismissible do %>
        <.link
          href={"/announcements/#{@announcement.id}/dismiss"}
          method="post"
          class="btn btn-xs btn-ghost btn-circle mt-0.5 flex-shrink-0 text-base-content/60 hover:bg-base-300 hover:text-base-content"
          aria-label="Dismiss"
        >
          <.icon name="hero-x-mark" class="h-3 w-3" />
        </.link>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders multiple system announcements.

  ## Examples

      <.announcements announcements={@announcements} />
      <.announcements announcements={@announcements} dismissible />

  """
  attr :announcements, :list, default: []
  attr :dismissible, :boolean, default: false
  attr :class, :string, default: nil

  def announcements(assigns) do
    ~H"""
    <div class={["space-y-3", @class]} id="system-announcements">
      <%= for announcement <- @announcements do %>
        <.announcement
          announcement={announcement}
          dismissible={@dismissible}
          id={"announcement-#{announcement.id}"}
        />
      <% end %>
    </div>
    """
  end

  # Helper functions for announcements

  defp announcement_classes("info"), do: "system-announcement--info"
  defp announcement_classes("warning"), do: "system-announcement--warning"
  defp announcement_classes("maintenance"), do: "system-announcement--maintenance"
  defp announcement_classes("feature"), do: "system-announcement--feature"
  defp announcement_classes("urgent"), do: "system-announcement--urgent"
  defp announcement_classes(_), do: "system-announcement--info"

  defp announcement_label("warning"), do: "Warning"
  defp announcement_label("maintenance"), do: "Maintenance"
  defp announcement_label("feature"), do: "Feature"
  defp announcement_label("urgent"), do: "Urgent"
  defp announcement_label(_), do: "Notice"

  defp announcement_icon("info"), do: "hero-information-circle"
  defp announcement_icon("warning"), do: "hero-exclamation-triangle"
  defp announcement_icon("maintenance"), do: "hero-cog-6-tooth"
  defp announcement_icon("feature"), do: "hero-sparkles"
  defp announcement_icon("urgent"), do: "hero-exclamation-circle"
  defp announcement_icon(_), do: "hero-information-circle"

  # Import icon component
  defp icon(assigns) do
    ElektrineWeb.Components.UI.Icon.icon(assigns)
  end
end
