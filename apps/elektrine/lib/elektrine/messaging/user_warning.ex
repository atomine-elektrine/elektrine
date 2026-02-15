defmodule Elektrine.Messaging.UserWarning do
  @moduledoc """
  Schema for tracking warnings issued to users in communities.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_warnings" do
    field :reason, :string
    field :severity, :string, default: "low"
    field :acknowledged_at, :utc_datetime

    belongs_to :conversation, Elektrine.Messaging.Conversation
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :warned_by, Elektrine.Accounts.User
    belongs_to :related_message, Elektrine.Messaging.Message

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(warning, attrs) do
    warning
    |> cast(attrs, [
      :conversation_id,
      :user_id,
      :warned_by_id,
      :reason,
      :severity,
      :acknowledged_at,
      :related_message_id
    ])
    |> validate_required([:conversation_id, :user_id, :warned_by_id, :reason])
    |> validate_inclusion(:severity, ["low", "medium", "high"])
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:warned_by_id)
    |> foreign_key_constraint(:related_message_id)
  end
end
