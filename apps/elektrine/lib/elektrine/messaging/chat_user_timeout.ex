defmodule Elektrine.Messaging.ChatUserTimeout do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_user_timeouts" do
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :conversation, Elektrine.Messaging.ChatConversation
    belongs_to :created_by, Elektrine.Accounts.User
    field :timeout_until, :utc_datetime
    field :reason, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(user_timeout, attrs) do
    user_timeout
    |> cast(attrs, [:user_id, :conversation_id, :timeout_until, :reason, :created_by_id])
    |> validate_required([:user_id, :conversation_id, :timeout_until, :created_by_id])
    |> unique_constraint([:user_id, :conversation_id],
      name: :chat_user_timeouts_user_conversation_unique
    )
  end
end
