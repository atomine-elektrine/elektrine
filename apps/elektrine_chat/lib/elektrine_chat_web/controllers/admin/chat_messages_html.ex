defmodule ElektrineChatWeb.Admin.ChatMessagesHTML do
  @moduledoc """
  View helpers and templates for admin Arblarg chat message views.
  """

  use ElektrineChatWeb, :html

  embed_templates "chat_messages_html/*"

  def truncate_content(nil), do: ""

  def truncate_content(content) when is_binary(content) do
    if String.length(content) > 150 do
      String.slice(content, 0, 150) <> "..."
    else
      content
    end
  end
end
