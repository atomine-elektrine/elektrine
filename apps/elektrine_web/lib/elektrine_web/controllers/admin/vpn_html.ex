defmodule ElektrineWeb.Admin.VPNHTML do
  @moduledoc """
  View helpers and templates for admin VPN management.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate vpn_dashboard(assigns), to: ElektrineWeb.AdminHTML
  defdelegate new_vpn_server(assigns), to: ElektrineWeb.AdminHTML
  defdelegate edit_vpn_server(assigns), to: ElektrineWeb.AdminHTML
  defdelegate confirm_delete_vpn_server(assigns), to: ElektrineWeb.AdminHTML
  defdelegate vpn_users(assigns), to: ElektrineWeb.AdminHTML
  defdelegate edit_vpn_user_config(assigns), to: ElektrineWeb.AdminHTML
end
