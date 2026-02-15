defmodule ElektrineWeb.Admin.ModerationHTML do
  @moduledoc """
  View helpers and templates for admin content moderation.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate content_moderation(assigns), to: ElektrineWeb.AdminHTML
  defdelegate unsubscribe_stats(assigns), to: ElektrineWeb.AdminHTML
end
