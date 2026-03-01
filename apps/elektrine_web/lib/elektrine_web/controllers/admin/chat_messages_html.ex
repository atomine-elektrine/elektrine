defmodule ElektrineWeb.Admin.ChatMessagesHTML do
  @moduledoc """
  View helpers and templates for admin Arblarg chat message views.
  """

  use ElektrineWeb, :html

  defdelegate chat_messages(assigns), to: ElektrineWeb.AdminHTML
  defdelegate view_chat_message(assigns), to: ElektrineWeb.AdminHTML
end
