defmodule ElektrineWeb.Admin.InviteCodesHTML do
  @moduledoc """
  View helpers and templates for admin invite codes.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate invite_codes(assigns), to: ElektrineWeb.AdminHTML
  defdelegate new_invite_code(assigns), to: ElektrineWeb.AdminHTML
  defdelegate edit_invite_code(assigns), to: ElektrineWeb.AdminHTML
end
