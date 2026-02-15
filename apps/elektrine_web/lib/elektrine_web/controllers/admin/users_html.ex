defmodule ElektrineWeb.Admin.UsersHTML do
  @moduledoc """
  View helpers and templates for admin user management.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate users(assigns), to: ElektrineWeb.AdminHTML
  defdelegate new(assigns), to: ElektrineWeb.AdminHTML
  defdelegate edit(assigns), to: ElektrineWeb.AdminHTML
  defdelegate ban(assigns), to: ElektrineWeb.AdminHTML
  defdelegate multi_accounts(assigns), to: ElektrineWeb.AdminHTML
  defdelegate account_lookup(assigns), to: ElektrineWeb.AdminHTML
end
