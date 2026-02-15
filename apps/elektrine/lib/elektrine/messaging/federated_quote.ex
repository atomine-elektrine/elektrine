defmodule Elektrine.Messaging.FederatedQuote do
  @moduledoc """
  Tracks quote posts from remote ActivityPub actors that quote local posts.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "federated_quotes" do
    belongs_to :message, Elektrine.Messaging.Message
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    field :activitypub_id, :string

    timestamps()
  end

  @doc false
  def changeset(quote_record, attrs) do
    quote_record
    |> cast(attrs, [:message_id, :remote_actor_id, :activitypub_id])
    |> validate_required([:message_id, :remote_actor_id, :activitypub_id])
    |> unique_constraint([:message_id, :remote_actor_id])
    |> unique_constraint(:activitypub_id)
  end
end
