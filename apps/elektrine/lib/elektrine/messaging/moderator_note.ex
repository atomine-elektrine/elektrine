defmodule Elektrine.Messaging.ModeratorNote do
  @moduledoc """
  Schema for private notes about users visible only to moderators.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "moderator_notes" do
    field :note, :string
    field :is_important, :boolean, default: false

    belongs_to :conversation, Elektrine.Messaging.Conversation
    belongs_to :target_user, Elektrine.Accounts.User
    belongs_to :created_by, Elektrine.Accounts.User

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [:conversation_id, :target_user_id, :created_by_id, :note, :is_important])
    |> validate_required([:conversation_id, :target_user_id, :created_by_id, :note])
    |> validate_length(:note, min: 1, max: 1000)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:target_user_id)
    |> foreign_key_constraint(:created_by_id)
  end
end
