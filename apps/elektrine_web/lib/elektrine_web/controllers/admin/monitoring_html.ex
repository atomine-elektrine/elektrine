defmodule ElektrineWeb.Admin.MonitoringHTML do
  @moduledoc """
  View helpers and templates for admin monitoring functions.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate active_users(assigns), to: ElektrineWeb.AdminHTML
  defdelegate imap_users(assigns), to: ElektrineWeb.AdminHTML
  defdelegate pop3_users(assigns), to: ElektrineWeb.AdminHTML
  defdelegate two_factor_status(assigns), to: ElektrineWeb.AdminHTML
end
