defmodule Elektrine.Messaging.UserPostTimestamp do
  @moduledoc """
  Schema for tracking when users last posted in a community (for slow mode).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_post_timestamps" do
    field :last_post_at, :utc_datetime

    belongs_to :conversation, Elektrine.Messaging.Conversation
    belongs_to :user, Elektrine.Accounts.User

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(timestamp, attrs) do
    timestamp
    |> cast(attrs, [:conversation_id, :user_id, :last_post_at])
    |> validate_required([:conversation_id, :user_id, :last_post_at])
    |> unique_constraint([:conversation_id, :user_id])
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_id)
  end
end
