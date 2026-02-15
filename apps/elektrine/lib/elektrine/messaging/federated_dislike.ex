defmodule Elektrine.Messaging.FederatedDislike do
  @moduledoc """
  Tracks dislikes (downvotes) from remote ActivityPub actors to prevent duplicate dislike spam.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "federated_dislikes" do
    belongs_to :message, Elektrine.Messaging.Message
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    field :activitypub_id, :string

    timestamps()
  end

  @doc false
  def changeset(dislike, attrs) do
    dislike
    |> cast(attrs, [:message_id, :remote_actor_id, :activitypub_id])
    |> validate_required([:message_id, :remote_actor_id])
    |> unique_constraint([:message_id, :remote_actor_id])
  end
end
