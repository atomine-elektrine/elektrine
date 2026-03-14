defmodule ElektrineWeb.Admin.MessagesHTML do
  @moduledoc """
  View helpers and templates for admin message viewing.
  """

  use ElektrineEmailWeb, :html

  embed_templates "messages_html/*"
end
