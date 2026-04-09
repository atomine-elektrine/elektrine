defmodule Elektrine.Messaging.FederationMembershipState do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @valid_roles ~w(owner admin moderator member readonly)
  @valid_states ~w(active invited left banned)

  schema "messaging_federation_membership_states" do
    field :origin_domain, :string
    field :role, :string
    field :state, :string
    field :joined_at_remote, :utc_datetime
    field :updated_at_remote, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :conversation, Elektrine.Messaging.ChatConversation
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :origin_domain,
      :role,
      :state,
      :joined_at_remote,
      :updated_at_remote,
      :metadata,
      :conversation_id,
      :remote_actor_id
    ])
    |> validate_required([
      :origin_domain,
      :role,
      :state,
      :updated_at_remote,
      :conversation_id,
      :remote_actor_id
    ])
    |> validate_length(:origin_domain, max: 255)
    |> validate_inclusion(:role, @valid_roles)
    |> validate_inclusion(:state, @valid_states)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint([:conversation_id, :remote_actor_id],
      name: :messaging_federation_membership_states_unique
    )
  end
end
