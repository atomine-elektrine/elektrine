defmodule ElektrineWeb.Components.UI.PillSwitcher do
  @moduledoc """
  Pill-shaped option switcher for filters and view toggles.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS
  import ElektrineWeb.Components.UI.Icon

  attr :options, :list, required: true
  attr :active, :any, required: true
  attr :event, :string, required: true
  attr :param, :string, default: "value"
  attr :class, :string, default: nil
  attr :size, :string, default: "sm", values: ["xs", "sm", "md"]

  def pill_switcher(assigns) do
    ~H"""
    <div class={["flex flex-wrap gap-2", @class]}>
      <%= for option <- @options do %>
        <button
          type="button"
          phx-click={JS.push(@event, value: %{@param => option_value(option)})}
          class={pill_class(@active == option_value(option), @size)}
        >
          <.icon :if={option[:icon]} name={option[:icon]} class="h-4 w-4" />
          <span>{option[:label] || option.label}</span>
          <span :if={option[:count] != nil} class="opacity-70">({option[:count]})</span>
        </button>
      <% end %>
    </div>
    """
  end

  defp option_value(option), do: option[:value] || option.value

  defp pill_class(active, size) do
    [
      "btn rounded-full",
      case size do
        "xs" -> "btn-xs"
        "md" -> "btn-md"
        _ -> "btn-sm"
      end,
      if(active, do: "btn-secondary", else: "btn-ghost")
    ]
  end
end
