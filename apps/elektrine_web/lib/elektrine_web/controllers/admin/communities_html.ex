defmodule ElektrineWeb.Admin.CommunitiesHTML do
  @moduledoc """
  View helpers and templates for admin communities.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate communities(assigns), to: ElektrineWeb.AdminHTML
  defdelegate show_community(assigns), to: ElektrineWeb.AdminHTML
end
