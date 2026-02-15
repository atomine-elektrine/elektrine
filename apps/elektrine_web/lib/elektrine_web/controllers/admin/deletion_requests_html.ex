defmodule ElektrineWeb.Admin.DeletionRequestsHTML do
  @moduledoc """
  View helpers and templates for admin deletion requests.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate deletion_requests(assigns), to: ElektrineWeb.AdminHTML
  defdelegate show_deletion_request(assigns), to: ElektrineWeb.AdminHTML
end
