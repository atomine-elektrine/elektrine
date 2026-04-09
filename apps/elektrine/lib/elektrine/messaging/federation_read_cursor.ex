defmodule Elektrine.Messaging.FederationReadCursor do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_federation_read_cursors" do
    field :origin_domain, :string
    field :read_at, :utc_datetime
    field :read_through_sequence, :integer

    belongs_to :conversation, Elektrine.Messaging.ChatConversation
    belongs_to :chat_message, Elektrine.Messaging.ChatMessage
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [
      :origin_domain,
      :read_at,
      :read_through_sequence,
      :conversation_id,
      :chat_message_id,
      :remote_actor_id
    ])
    |> validate_required([
      :origin_domain,
      :read_at,
      :conversation_id,
      :chat_message_id,
      :remote_actor_id
    ])
    |> validate_length(:origin_domain, max: 255)
    |> validate_number(:read_through_sequence, greater_than: 0)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:chat_message_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint([:conversation_id, :remote_actor_id],
      name: :messaging_federation_read_cursors_unique
    )
  end
end
