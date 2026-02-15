defmodule ElektrineWeb.Admin.MessagesHTML do
  @moduledoc """
  View helpers and templates for admin message viewing.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate messages(assigns), to: ElektrineWeb.AdminHTML
  defdelegate view_message(assigns), to: ElektrineWeb.AdminHTML
  defdelegate user_messages(assigns), to: ElektrineWeb.AdminHTML
  defdelegate view_user_message(assigns), to: ElektrineWeb.AdminHTML
end
