defmodule ElektrineWeb.Admin.MailboxesHTML do
  @moduledoc """
  View helpers and templates for admin mailbox management.
  """

  use ElektrineWeb, :html

  # Delegate template rendering to AdminHTML since templates are in admin_html directory
  defdelegate mailboxes(assigns), to: ElektrineWeb.AdminHTML
  defdelegate mailbox_integrity(assigns), to: ElektrineWeb.AdminHTML
end
