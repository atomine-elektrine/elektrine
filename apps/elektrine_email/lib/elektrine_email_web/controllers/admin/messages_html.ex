defmodule ElektrineEmailWeb.Admin.MessagesHTML do
  @moduledoc """
  View helpers and templates for admin message viewing.
  """

  use ElektrineEmailWeb, :html

  embed_templates "messages_html/*"

  def message_status_label("draft"), do: "Draft"
  def message_status_label("received"), do: "Received"
  def message_status_label("sent"), do: "Sent"
  def message_status_label(status) when is_binary(status), do: String.capitalize(status)
  def message_status_label(_status), do: "Unknown"

  def message_status_badge_class("draft"), do: "badge-warning"
  def message_status_badge_class("received"), do: "badge-info"
  def message_status_badge_class("sent"), do: "badge-success"
  def message_status_badge_class(_status), do: "badge-ghost"

  def message_status_description("draft"),
    do: "Drafts are saved compose records and may not have recipients yet."

  def message_status_description("sent"), do: "Outbound message."
  def message_status_description("received"), do: "Inbound message."
  def message_status_description(_status), do: "Message status."
end
