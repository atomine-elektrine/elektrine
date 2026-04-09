defmodule Elektrine.Messaging.FederationRoomPresenceState do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(online idle dnd offline invisible)

  schema "messaging_federation_room_presence_states" do
    field :origin_domain, :string
    field :status, :string
    field :activities, :map, default: %{}
    field :updated_at_remote, :utc_datetime
    field :expires_at_remote, :utc_datetime

    belongs_to :conversation, Elektrine.Messaging.ChatConversation
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :conversation_id,
      :remote_actor_id,
      :origin_domain,
      :status,
      :activities,
      :updated_at_remote,
      :expires_at_remote
    ])
    |> validate_required([
      :conversation_id,
      :remote_actor_id,
      :origin_domain,
      :status,
      :updated_at_remote
    ])
    |> validate_length(:origin_domain, max: 255)
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint([:conversation_id, :remote_actor_id],
      name: :messaging_federation_room_presence_states_unique
    )
  end
end
