defmodule Elektrine.Messaging.ChatConversationMember do
  @moduledoc false

  use Elektrine.Messaging.MemberSchemaBase,
    table: "chat_conversation_members",
    conversation: Elektrine.Messaging.ChatConversation,
    message: Elektrine.Messaging.ChatMessage
end
