defmodule ElektrineWeb.Components.UI.ActionToolbar do
  @moduledoc """
  Compact toolbar for secondary page and modal actions.
  """

  use Phoenix.Component

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def action_toolbar(assigns) do
    ~H"""
    <div class={["flex flex-wrap items-center gap-2", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
