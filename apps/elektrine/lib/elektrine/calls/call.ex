defmodule Elektrine.Calls.Call do
  use Ecto.Schema
  import Ecto.Changeset

  schema "calls" do
    belongs_to :caller, Elektrine.Accounts.User, foreign_key: :caller_id
    belongs_to :callee, Elektrine.Accounts.User, foreign_key: :callee_id
    belongs_to :conversation, Elektrine.Messaging.Conversation

    # "audio" or "video"
    field :call_type, :string
    # "initiated", "ringing", "active", "ended", "rejected", "missed", "failed"
    field :status, :string
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :duration_seconds, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(call, attrs) do
    call
    |> cast(attrs, [
      :caller_id,
      :callee_id,
      :conversation_id,
      :call_type,
      :status,
      :started_at,
      :ended_at,
      :duration_seconds
    ])
    |> validate_required([:caller_id, :callee_id, :call_type, :status])
    |> validate_inclusion(:call_type, ["audio", "video"])
    |> validate_inclusion(:status, [
      "initiated",
      "ringing",
      "active",
      "ended",
      "rejected",
      "missed",
      "failed"
    ])
    |> foreign_key_constraint(:caller_id)
    |> foreign_key_constraint(:callee_id)
    |> foreign_key_constraint(:conversation_id)
  end
end
