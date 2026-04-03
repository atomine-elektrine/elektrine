defmodule ElektrineWeb.Components.Platform.ZNav do
  @moduledoc """
  Backward-compatible alias for the shared platform navigation component.
  """

  def z_nav(assigns), do: ElektrineWeb.Components.Platform.ENav.z_nav(assigns)
end
