defmodule ElektrineWeb.Components.Platform.ElektrineNav do
  @moduledoc """
  Compatibility wrapper for the unified product navigation.
  """
  use Phoenix.Component
  alias ElektrineWeb.Components.Platform.ZNav

  @doc """
  Renders the unified product navigation tabs.

  ## Examples

      <.elektrine_nav active_tab="email" />

  """
  attr :active_tab, :string, default: "email"

  def elektrine_nav(assigns) do
    ZNav.z_nav(assigns)
  end
end
