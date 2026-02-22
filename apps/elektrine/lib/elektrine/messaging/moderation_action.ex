defmodule Elektrine.Messaging.ModerationAction do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "moderation_actions" do
    field :action_type, :string
    field :reason, :string
    field :duration, :integer
    field :details, :map

    belongs_to :target_user, Elektrine.Accounts.User
    belongs_to :moderator, Elektrine.Accounts.User
    belongs_to :conversation, Elektrine.Messaging.Conversation

    timestamps(type: :utc_datetime)
  end

  @valid_actions ~w(timeout kick delete_message ban warn)

  @doc false
  def changeset(moderation_action, attrs) do
    moderation_action
    |> cast(attrs, [
      :action_type,
      :target_user_id,
      :moderator_id,
      :conversation_id,
      :reason,
      :duration,
      :details
    ])
    |> validate_required([:action_type, :target_user_id, :moderator_id])
    |> validate_inclusion(:action_type, @valid_actions)
  end

  def log_action(action_type, target_user_id, moderator_id, opts \\ []) do
    attrs = %{
      action_type: action_type,
      target_user_id: target_user_id,
      moderator_id: moderator_id,
      conversation_id: Keyword.get(opts, :conversation_id),
      reason: Keyword.get(opts, :reason),
      duration: Keyword.get(opts, :duration),
      details: Keyword.get(opts, :details, %{})
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Elektrine.Repo.insert()
  end
end
