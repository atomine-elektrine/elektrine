defmodule Elektrine.Messaging.FederationExtensionEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_federation_extension_events" do
    field :event_type, :string
    field :origin_domain, :string
    field :event_key, :string
    field :status, :string
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime

    belongs_to :server, Elektrine.Messaging.Server
    belongs_to :conversation, Elektrine.Messaging.ChatConversation

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_type,
      :origin_domain,
      :event_key,
      :status,
      :payload,
      :occurred_at,
      :server_id,
      :conversation_id
    ])
    |> validate_required([:event_type, :origin_domain, :event_key])
    |> validate_length(:event_type, max: 160)
    |> validate_length(:origin_domain, max: 255)
    |> validate_length(:event_key, max: 500)
    |> foreign_key_constraint(:server_id)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint([:event_type, :origin_domain, :event_key],
      name: :messaging_federation_extension_events_unique
    )
  end
end
