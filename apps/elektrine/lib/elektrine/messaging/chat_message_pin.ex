defmodule Elektrine.Messaging.ChatMessagePin do
  @moduledoc """
  Schema for pinned chat messages.

  A join table between conversations and messages so pin metadata (who pinned
  the message and when) is preserved. Each message can be pinned at most once.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_message_pins" do
    belongs_to :conversation, Elektrine.Messaging.ChatConversation
    belongs_to :message, Elektrine.Messaging.ChatMessage
    belongs_to :pinned_by, Elektrine.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(pin, attrs) do
    pin
    |> cast(attrs, [:conversation_id, :message_id, :pinned_by_id])
    |> validate_required([:conversation_id, :message_id])
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:pinned_by_id)
    |> unique_constraint(:message_id)
  end
end
