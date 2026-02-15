defmodule Elektrine.Friends.FriendRequest do
  @moduledoc """
  Schema for friend requests between users, managing the lifecycle of friendship connections.
  Supports pending, accepted, and rejected statuses with optional messages.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "friend_requests" do
    belongs_to :requester, Elektrine.Accounts.User
    belongs_to :recipient, Elektrine.Accounts.User

    # "pending", "accepted", "rejected"
    field :status, :string
    # Optional message with request
    field :message, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(friend_request, attrs) do
    friend_request
    |> cast(attrs, [:requester_id, :recipient_id, :status, :message])
    |> validate_required([:requester_id, :recipient_id, :status])
    |> validate_inclusion(:status, ["pending", "accepted", "rejected"])
    |> validate_length(:message, max: 500)
    |> foreign_key_constraint(:requester_id)
    |> foreign_key_constraint(:recipient_id)
    |> unique_constraint([:requester_id, :recipient_id])
  end
end
