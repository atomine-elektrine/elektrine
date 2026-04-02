defmodule ElektrineWeb.Components.Chat.Call do
  @moduledoc false
  defdelegate call_buttons(assigns), to: ElektrineChatWeb.Components.Chat.Call
  defdelegate incoming_call_modal(assigns), to: ElektrineChatWeb.Components.Chat.Call
  defdelegate active_call_overlay(assigns), to: ElektrineChatWeb.Components.Chat.Call
end
