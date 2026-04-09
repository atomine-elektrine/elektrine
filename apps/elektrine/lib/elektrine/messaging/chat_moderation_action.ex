defmodule Elektrine.Messaging.ChatModerationAction do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_moderation_actions" do
    field :action_type, :string
    field :reason, :string
    field :duration, :integer
    field :details, :map

    belongs_to :target_user, Elektrine.Accounts.User
    belongs_to :moderator, Elektrine.Accounts.User
    belongs_to :conversation, Elektrine.Messaging.ChatConversation

    timestamps(type: :utc_datetime)
  end

  @valid_actions ~w(timeout kick delete_message ban warn)

  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :action_type,
      :target_user_id,
      :moderator_id,
      :conversation_id,
      :reason,
      :duration,
      :details
    ])
    |> validate_required([:action_type, :target_user_id, :moderator_id, :conversation_id])
    |> validate_inclusion(:action_type, @valid_actions)
  end
end
