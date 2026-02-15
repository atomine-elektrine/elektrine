defmodule ElektrineWeb.Admin.AnnouncementsHTML do
  @moduledoc """
  View helpers and templates for admin announcements.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate announcements(assigns), to: ElektrineWeb.AdminHTML
  defdelegate new_announcement(assigns), to: ElektrineWeb.AdminHTML
  defdelegate edit_announcement(assigns), to: ElektrineWeb.AdminHTML
end
