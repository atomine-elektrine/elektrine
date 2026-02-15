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
        "flex items-start gap-2 py-2 px-3 sm:px-4 rounded-lg text-sm",
        announcement_classes(@announcement.type),
        @class
      ]}
      id={@id}
    >
      <.icon
        name={announcement_icon(@announcement.type)}
        class="h-4 w-4 flex-shrink-0 mt-0.5"
      />
      <div class="flex-1 min-w-0">
        <span class="font-semibold">{@announcement.title}:</span>
        <span class="opacity-90">{String.trim(@announcement.content)}</span>
      </div>
      <%= if @dismissible do %>
        <.link
          href={"/announcements/#{@announcement.id}/dismiss"}
          method="post"
          class="btn btn-xs btn-ghost btn-circle opacity-70 hover:opacity-100 flex-shrink-0"
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
    <div class={["space-y-1", @class]} id="system-announcements">
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

  defp announcement_classes("info"), do: "bg-info/20 text-info"
  defp announcement_classes("warning"), do: "bg-warning/20 text-warning"
  defp announcement_classes("maintenance"), do: "bg-base-300 text-base-content"
  defp announcement_classes("feature"), do: "bg-success/20 text-success"
  defp announcement_classes("urgent"), do: "bg-error/20 text-error"
  defp announcement_classes(_), do: "bg-info/20 text-info"

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
