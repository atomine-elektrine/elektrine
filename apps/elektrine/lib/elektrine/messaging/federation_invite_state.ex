defmodule Elektrine.Messaging.FederationInviteState do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @valid_roles ~w(owner admin moderator member readonly)
  @valid_states ~w(pending accepted declined revoked)

  schema "messaging_federation_invite_states" do
    field :origin_domain, :string
    field :actor_uri, :string
    field :actor_payload, :map, default: %{}
    field :target_uri, :string
    field :target_payload, :map, default: %{}
    field :role, :string
    field :state, :string
    field :invited_at_remote, :utc_datetime
    field :updated_at_remote, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :conversation, Elektrine.Messaging.Conversation

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(invite_state, attrs) do
    invite_state
    |> cast(attrs, [
      :origin_domain,
      :actor_uri,
      :actor_payload,
      :target_uri,
      :target_payload,
      :role,
      :state,
      :invited_at_remote,
      :updated_at_remote,
      :metadata,
      :conversation_id
    ])
    |> validate_required([
      :origin_domain,
      :actor_uri,
      :actor_payload,
      :target_uri,
      :target_payload,
      :role,
      :state,
      :updated_at_remote,
      :conversation_id
    ])
    |> validate_length(:origin_domain, max: 255)
    |> validate_length(:actor_uri, max: 500)
    |> validate_length(:target_uri, max: 500)
    |> validate_inclusion(:role, @valid_roles)
    |> validate_inclusion(:state, @valid_states)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint([:conversation_id, :target_uri],
      name: :messaging_federation_invite_states_unique
    )
  end
end
