defmodule ElektrineWeb.Components.Platform.ElektrineNav do
  @moduledoc """
  Compatibility wrapper for the unified product navigation.
  """
  use Phoenix.Component
  alias ElektrineWeb.Components.Platform.ENav

  @doc """
  Renders the unified product navigation tabs.

  ## Examples

      <.elektrine_nav active_tab="email" />

  """
  attr :active_tab, :string, default: "email"
  attr :class, :string, default: "mb-6"
  attr :current_user, :any, default: nil

  def elektrine_nav(assigns) do
    ENav.e_nav(assigns)
  end
end
