defmodule ElektrineWeb.Admin.AliasesHTML do
  @moduledoc """
  View helpers and templates for admin alias management.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate aliases(assigns), to: ElektrineWeb.AdminHTML
  defdelegate forwarded_messages(assigns), to: ElektrineWeb.AdminHTML
end
