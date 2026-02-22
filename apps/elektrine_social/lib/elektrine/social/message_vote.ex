defmodule Elektrine.Social.MessageVote do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "message_votes" do
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :message, Elektrine.Messaging.Message
    field :vote_type, :string

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:user_id, :message_id, :vote_type])
    |> validate_required([:user_id, :message_id, :vote_type])
    |> validate_inclusion(:vote_type, ["up", "down"])
    |> unique_constraint([:user_id, :message_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:message_id)
  end
end
