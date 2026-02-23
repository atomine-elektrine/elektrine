defmodule Elektrine.Messaging.ChatUserHiddenMessage do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_user_hidden_messages" do
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :chat_message, Elektrine.Messaging.ChatMessage

    field :hidden_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(hidden_message, attrs) do
    hidden_message
    |> cast(attrs, [:user_id, :chat_message_id, :hidden_at])
    |> validate_required([:user_id, :chat_message_id, :hidden_at])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:chat_message_id)
    |> unique_constraint([:user_id, :chat_message_id],
      name: :chat_user_hidden_messages_user_message_unique
    )
  end
end
