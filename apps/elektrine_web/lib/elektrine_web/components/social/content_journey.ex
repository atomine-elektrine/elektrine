defmodule ElektrineWeb.Components.Social.ContentJourney do
  @moduledoc """
  Component that displays the journey of content across contexts.
  Shows users how content has flowed between Chat, Timeline, and Discussions.
  """
  use Phoenix.Component
  import ElektrineWeb.CoreComponents

  @doc """
  Renders a content journey trail showing where content came from and where it's going.
  """
  attr :message, :map, required: true
  attr :context, :string, default: "timeline"
  attr :class, :string, default: ""

  def content_journey(assigns) do
    # Use Map.get for fields that may not exist on ChatMessage
    assigns = assign(assigns, :promoted_from, Map.get(assigns.message, :promoted_from))

    ~H"""
    <!-- Content Journey Trail - Only show if there's no embedded post -->
    <%= if should_show_journey?(@message) do %>
      <div class={["inline-flex items-center gap-1", @class]}>
        <%= cond do %>
          <% @promoted_from == "chat" -> %>
            <span class="inline-flex items-center gap-1 px-2 py-0.5 bg-primary/10 text-primary rounded-full text-xs">
              <.icon name="hero-chat-bubble-left-right" class="w-3 h-3" />
              <span>from chat</span>
            </span>
          <% @promoted_from == "timeline" -> %>
            <span class="inline-flex items-center gap-1 px-2 py-0.5 bg-success/10 text-success rounded-full text-xs">
              <.icon name="hero-rectangle-stack" class="w-3 h-3" />
              <span>from timeline</span>
            </span>
          <% @promoted_from == "discussion" -> %>
            <span class="inline-flex items-center gap-1 px-2 py-0.5 bg-info/10 text-info rounded-full text-xs">
              <.icon name="hero-chat-bubble-bottom-center-text" class="w-3 h-3" />
              <span>from discussion</span>
            </span>
          <% true -> %>
            <!-- No badge for other cases -->
        <% end %>
      </div>
    <% end %>
    """
  end

  # Private helper functions

  # Only show journey badges if there's no embedded post
  defp should_show_journey?(nil), do: false

  defp should_show_journey?(message) do
    # Don't show journey if there's an embedded post (it already shows the origin)
    # Use Map.get for fields that may not exist on ChatMessage
    is_nil(Map.get(message, :shared_message_id)) && has_journey_data?(message)
  end

  defp has_journey_data?(message) do
    # Use Map.get for fields that may not exist on ChatMessage
    Map.get(message, :promoted_from) != nil || Map.get(message, :share_type) != nil
  end
end
