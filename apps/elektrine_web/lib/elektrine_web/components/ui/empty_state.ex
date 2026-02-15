defmodule ElektrineWeb.Components.UI.EmptyState do
  @moduledoc """
  Empty state components for displaying when no content is available.

  Provides a consistent, user-friendly way to communicate when lists,
  searches, or other content areas are empty.
  """
  use Phoenix.Component
  import ElektrineWeb.Components.UI.Icon

  @doc """
  Renders an empty state display with icon, message, and optional action button.

  Used to provide feedback when there's no content to display, with an
  optional call-to-action button to help users take the next step.

  ## Examples

      <.empty_state
        icon="hero-inbox"
        title="No messages"
        description="Your inbox is empty. Check back later for new messages."
      />

      <.empty_state
        icon="hero-magnifying-glass"
        title="No results found"
        description="Try adjusting your search terms or filters."
        style="info"
      />

      <.empty_state
        icon="hero-document-plus"
        title="No documents"
        description="Get started by creating your first document."
        action_text="Create Document"
        action_event="create_document"
        style="success"
      />

      <.empty_state
        icon="hero-shield-check"
        title="All clear!"
        description="No security alerts at this time."
        style="success"
        class="py-12"
      />
  """
  attr :icon, :string, required: true, doc: "Heroicon name (e.g., 'hero-inbox')"
  attr :title, :string, required: true, doc: "Empty state title/heading"
  attr :description, :string, default: nil, doc: "Optional description text"
  attr :action_text, :string, default: nil, doc: "Optional action button text"

  attr :action_event, :string,
    default: nil,
    doc: "Phoenix LiveView event to trigger on button click"

  attr :action_href, :string, default: nil, doc: "Optional href for action button"

  attr :style, :string,
    default: "default",
    values: ["default", "info", "success", "warning"],
    doc: "Visual style variant"

  attr :size, :string, default: "md", values: ["sm", "md", "lg"], doc: "Size variant"
  attr :class, :string, default: nil, doc: "Additional CSS classes"
  attr :rest, :global, doc: "Additional HTML attributes"
  slot :actions, doc: "Custom action buttons slot"

  def empty_state(assigns) do
    ~H"""
    <div class={["text-center px-4", size_classes(@size), @class]} {@rest}>
      <div class={icon_wrapper_classes(@style)}>
        <.icon name={@icon} class={icon_size_classes(@size)} />
      </div>

      <h3 class={["text-lg font-semibold mb-2", title_size_classes(@size)]}>
        {@title}
      </h3>

      <%= if @description do %>
        <p class="text-base-content/70 mb-6 max-w-md mx-auto">
          {@description}
        </p>
      <% end %>

      <div class="flex flex-wrap gap-2 justify-center">
        <%= if @actions && @actions != [] do %>
          {render_slot(@actions)}
        <% else %>
          <%= if @action_text do %>
            <%= if @action_event do %>
              <button phx-click={@action_event} class={action_button_classes(@style)}>
                {@action_text}
              </button>
            <% end %>
            <%= if @action_href do %>
              <a href={@action_href} class={action_button_classes(@style)}>
                {@action_text}
              </a>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp size_classes("sm"), do: "py-6"
  defp size_classes("lg"), do: "py-16"
  defp size_classes(_), do: "py-12"

  defp icon_size_classes("sm"), do: "h-10 w-10 mx-auto mb-3"
  defp icon_size_classes("lg"), do: "h-20 w-20 mx-auto mb-6"
  defp icon_size_classes(_), do: "h-16 w-16 mx-auto mb-4 opacity-40"

  defp title_size_classes("sm"), do: "text-base"
  defp title_size_classes("lg"), do: "text-xl"
  defp title_size_classes(_), do: "text-lg"

  defp icon_wrapper_classes("info"), do: "text-info"
  defp icon_wrapper_classes("success"), do: "text-success"
  defp icon_wrapper_classes("warning"), do: "text-warning"
  defp icon_wrapper_classes(_), do: "text-base-content/30"

  defp action_button_classes("info"), do: "btn btn-info btn-sm"
  defp action_button_classes("success"), do: "btn btn-success btn-sm"
  defp action_button_classes("warning"), do: "btn btn-warning btn-sm"
  defp action_button_classes(_), do: "btn btn-primary btn-sm"
end
