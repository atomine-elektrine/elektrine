defmodule ElektrineWeb.Components.UI.FloatingPanel do
  @moduledoc """
  Floating glass surface for overlays, popovers, and detached panels.
  """

  use Phoenix.Component

  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def floating_panel(assigns) do
    ~H"""
    <div class={["glass-floating rounded-lg", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
