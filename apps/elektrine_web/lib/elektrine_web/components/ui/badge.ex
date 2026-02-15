defmodule ElektrineWeb.Components.UI.Badge do
  @moduledoc """
  Badge components for labels, status indicators, and counts.

  Provides reusable badge components with consistent styling using DaisyUI,
  including color variants, sizes, and specialized badge types.
  """
  use Phoenix.Component

  @doc """
  Renders a generic badge with customizable variant and size.

  Badges are small labels used to display status, categories, or other
  metadata in a compact form.

  ## Examples

      <.badge>Default</.badge>

      <.badge variant="primary">Primary</.badge>

      <.badge variant="success" size="lg">
        Success
      </.badge>

      <.badge variant="warning" size="sm">
        Warning
      </.badge>

      <.badge variant="error" pill>
        Error
      </.badge>

      <.badge variant="info" outline>
        Info
      </.badge>
  """
  attr :variant, :string,
    default: "default",
    values: [
      "default",
      "primary",
      "secondary",
      "accent",
      "success",
      "warning",
      "error",
      "info",
      "ghost"
    ],
    doc: "Badge color variant"

  attr :size, :string, default: "md", values: ["sm", "md", "lg"], doc: "Badge size"
  attr :outline, :boolean, default: false, doc: "Use outline style"
  attr :pill, :boolean, default: false, doc: "Use pill (fully rounded) style"
  attr :class, :string, default: nil, doc: "Additional CSS classes"
  attr :rest, :global, doc: "Additional HTML attributes"

  slot :inner_block, required: true, doc: "Badge content"

  def badge(assigns) do
    ~H"""
    <span class={badge_classes(assigns)} {@rest}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders a count badge for displaying numeric values.

  Commonly used for notification counts, message counts, or other
  numeric indicators. Supports a maximum display value.

  ## Examples

      <.count_badge count={5} />

      <.count_badge count={42} variant="error" />

      <.count_badge count={150} max={99} variant="primary" />
      <!-- Displays "99+" -->

      <.count_badge count={0} variant="success" />
      <!-- Displays nothing when count is 0 -->

      <.count_badge count={@unread_count} variant="warning" size="sm" />
  """
  attr :count, :integer, required: true, doc: "Numeric count to display"
  attr :max, :integer, default: nil, doc: "Maximum count to display (shows 'max+' if exceeded)"

  attr :variant, :string,
    default: "error",
    values: ["primary", "secondary", "accent", "success", "warning", "error", "info"],
    doc: "Badge color variant"

  attr :size, :string, default: "sm", values: ["sm", "md", "lg"], doc: "Badge size"
  attr :class, :string, default: nil, doc: "Additional CSS classes"
  attr :rest, :global, doc: "Additional HTML attributes"

  def count_badge(assigns) do
    ~H"""
    <%= if @count > 0 do %>
      <span class={count_badge_classes(assigns)} {@rest}>
        {format_count(@count, @max)}
      </span>
    <% end %>
    """
  end

  @doc """
  Renders a status indicator badge.

  Used to display user status, system status, or other state indicators
  with appropriate colors and optional pulse animation.

  ## Examples

      <.status_badge status="online" />

      <.status_badge status="offline" />

      <.status_badge status="busy" />

      <.status_badge status="away" />

      <.status_badge status="online" show_text />
      <!-- Displays "Online" with the badge -->

      <.status_badge status="busy" show_text size="lg" />
  """
  attr :status, :string,
    required: true,
    values: ["online", "offline", "busy", "away"],
    doc: "Status to display"

  attr :show_text, :boolean, default: false, doc: "Show status text alongside indicator"
  attr :size, :string, default: "md", values: ["sm", "md", "lg"], doc: "Badge size"
  attr :class, :string, default: nil, doc: "Additional CSS classes"
  attr :rest, :global, doc: "Additional HTML attributes"

  def status_badge(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-2", @class]} {@rest}>
      <span class={status_indicator_classes(@status, @size)}></span>
      <%= if @show_text do %>
        <span class={status_text_classes(@size)}>
          {status_text(@status)}
        </span>
      <% end %>
    </span>
    """
  end

  # Private helper functions

  defp badge_classes(assigns) do
    [
      "badge",
      variant_class(assigns.variant),
      size_class(assigns.size),
      if(assigns.outline, do: "badge-outline"),
      if(assigns.pill, do: "rounded-full"),
      assigns.class
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp count_badge_classes(assigns) do
    [
      "badge",
      variant_class(assigns.variant),
      size_class(assigns.size),
      assigns.class
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp variant_class("default"), do: nil
  defp variant_class("primary"), do: "badge-primary"
  defp variant_class("secondary"), do: "badge-secondary"
  defp variant_class("accent"), do: "badge-accent"
  defp variant_class("success"), do: "badge-success"
  defp variant_class("warning"), do: "badge-warning"
  defp variant_class("error"), do: "badge-error"
  defp variant_class("info"), do: "badge-info"
  defp variant_class("ghost"), do: "badge-ghost"
  defp variant_class(_), do: nil

  defp size_class("sm"), do: "badge-sm"
  defp size_class("md"), do: nil
  defp size_class("lg"), do: "badge-lg"
  defp size_class(_), do: nil

  defp format_count(count, nil), do: count
  defp format_count(count, max) when count > max, do: "#{max}+"
  defp format_count(count, _max), do: count

  defp status_indicator_classes(status, size) do
    base = "inline-block rounded-full"

    size_class =
      case size do
        "sm" -> "w-2 h-2"
        "md" -> "w-3 h-3"
        "lg" -> "w-4 h-4"
        _ -> "w-3 h-3"
      end

    color_class =
      case status do
        "online" -> "bg-success animate-pulse"
        "offline" -> "bg-base-content/30"
        "busy" -> "bg-error"
        "away" -> "bg-warning"
        _ -> "bg-base-content/30"
      end

    "#{base} #{size_class} #{color_class}"
  end

  defp status_text_classes("sm"), do: "text-xs text-base-content/80"
  defp status_text_classes("md"), do: "text-sm text-base-content/80"
  defp status_text_classes("lg"), do: "text-base text-base-content/80"
  defp status_text_classes(_), do: "text-sm text-base-content/80"

  defp status_text("online"), do: "Online"
  defp status_text("offline"), do: "Offline"
  defp status_text("busy"), do: "Busy"
  defp status_text("away"), do: "Away"
  defp status_text(status), do: String.capitalize(status)
end
