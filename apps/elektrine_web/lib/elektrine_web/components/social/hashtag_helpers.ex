defmodule ElektrineWeb.Components.Social.HashtagHelpers do
  @moduledoc """
  Helper functions for rendering hashtags in content.
  """

  use Phoenix.Component
  use ElektrineWeb, :verified_routes

  @doc """
  Component for rendering content with clickable hashtags.
  """
  attr :content, :string, required: true

  def content_with_hashtags(assigns) do
    # Trim content first to remove leading/trailing whitespace
    content = String.trim(assigns.content)

    # Split content by hashtags and render each part
    hashtag_regex = ~r/(#\w+)/
    parts = Regex.split(hashtag_regex, content, include_captures: true)

    assigns = assign(assigns, :parts, parts)

    ~H"""
    <span>
      <%= for {part, index} <- Enum.with_index(@parts) do %>
        <%= if String.starts_with?(part, "#") do %>
          <% hashtag_name = String.slice(part, 1..-1//1) %>
          <.link
            href={~p"/hashtag/#{String.downcase(hashtag_name)}"}
            class="text-primary hover:underline font-medium"
          >
            {part}
          </.link>
        <% else %>
          {if index == 0, do: String.trim_leading(part), else: part}
        <% end %>
      <% end %>
    </span>
    """
  end

  @doc """
  Component for displaying hashtag list.
  """
  attr :hashtags, :list, required: true
  attr :class, :string, default: ""

  def hashtag_list(assigns) do
    ~H"""
    <div class={["flex flex-wrap gap-1", @class]}>
      <%= for hashtag <- @hashtags do %>
        <.link
          href={~p"/hashtag/#{String.downcase(hashtag.name)}"}
          class="inline-flex items-center px-2 py-1 text-xs font-medium bg-primary/10 text-primary rounded-full hover:bg-primary/20 transition-colors"
        >
          #{hashtag.name}
        </.link>
      <% end %>
    </div>
    """
  end
end
