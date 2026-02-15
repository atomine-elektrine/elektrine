defmodule Elektrine.Messaging.FederatedBoost do
  @moduledoc """
  Tracks boosts (announces) from remote ActivityPub actors on local posts.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "federated_boosts" do
    belongs_to :message, Elektrine.Messaging.Message
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    field :activitypub_id, :string

    timestamps()
  end

  @doc false
  def changeset(boost, attrs) do
    boost
    |> cast(attrs, [:message_id, :remote_actor_id, :activitypub_id])
    |> validate_required([:message_id, :remote_actor_id])
    |> unique_constraint([:message_id, :remote_actor_id])
  end
end
