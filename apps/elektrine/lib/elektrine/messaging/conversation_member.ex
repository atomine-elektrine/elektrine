defmodule Elektrine.Social.ConversationMember do
  @moduledoc false

  alias Elektrine.Messaging.ChatConversationMember

  use Elektrine.Messaging.MemberSchemaBase,
    table: "conversation_members",
    conversation: Elektrine.Social.Conversation,
    message: Elektrine.Social.Message

  # In addition to the shared `%__MODULE__{}` clauses provided by the base
  # macro, this module also accepts `%ChatConversationMember{}` structs for the
  # permission predicates (cross-schema dispatch preserved from the original
  # implementation). The base-supplied `%__MODULE__{}` clauses are reached via
  # `super/1`.

  def can_send_messages?(%ChatConversationMember{role: "readonly"}), do: false
  def can_send_messages?(%ChatConversationMember{left_at: nil}), do: true
  def can_send_messages?(%ChatConversationMember{}), do: false
  def can_send_messages?(member), do: super(member)

  def admin?(%ChatConversationMember{role: "admin"}), do: true
  def admin?(%ChatConversationMember{}), do: false
  def admin?(member), do: super(member)
end
