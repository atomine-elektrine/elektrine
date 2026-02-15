defmodule Elektrine.ActivityPub.GroupFollow do
  @moduledoc """
  Schema representing a remote actor following a local Group actor (community).
  Used to track followers for community federation delivery.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "group_follows" do
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor
    belongs_to :group_actor, Elektrine.ActivityPub.Actor
    field :activitypub_id, :string
    field :pending, :boolean, default: false

    timestamps()
  end

  @doc false
  def changeset(group_follow, attrs) do
    group_follow
    |> cast(attrs, [:remote_actor_id, :group_actor_id, :activitypub_id, :pending])
    |> validate_required([:remote_actor_id, :group_actor_id])
    |> unique_constraint([:remote_actor_id, :group_actor_id])
  end
end
