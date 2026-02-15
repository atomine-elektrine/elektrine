defmodule ElektrineWeb.Admin.SubscriptionsHTML do
  @moduledoc """
  View helpers and templates for admin subscription products.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate subscriptions(assigns), to: ElektrineWeb.AdminHTML
  defdelegate new_product(assigns), to: ElektrineWeb.AdminHTML
  defdelegate edit_product(assigns), to: ElektrineWeb.AdminHTML
end
