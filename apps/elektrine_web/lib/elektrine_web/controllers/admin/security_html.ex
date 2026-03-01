defmodule ElektrineWeb.Admin.SecurityHTML do
  @moduledoc """
  View helpers and templates for admin security elevation.
  """

  use ElektrineWeb, :html

  defdelegate elevate(assigns), to: ElektrineWeb.AdminHTML
end
