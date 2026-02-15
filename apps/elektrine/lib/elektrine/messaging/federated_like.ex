defmodule Elektrine.Messaging.FederatedLike do
  @moduledoc """
  Tracks likes from remote ActivityPub actors to prevent duplicate like spam.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "federated_likes" do
    belongs_to :message, Elektrine.Messaging.Message
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    field :activitypub_id, :string

    timestamps()
  end

  @doc false
  def changeset(like, attrs) do
    like
    |> cast(attrs, [:message_id, :remote_actor_id, :activitypub_id])
    |> validate_required([:message_id, :remote_actor_id])
    |> unique_constraint([:message_id, :remote_actor_id])
  end
end
