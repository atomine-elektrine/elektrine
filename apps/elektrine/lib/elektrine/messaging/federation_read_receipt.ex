defmodule Elektrine.Messaging.FederationReadReceipt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_federation_read_receipts" do
    field :origin_domain, :string
    field :read_at, :utc_datetime

    belongs_to :chat_message, Elektrine.Messaging.ChatMessage
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:origin_domain, :read_at, :chat_message_id, :remote_actor_id])
    |> validate_required([:origin_domain, :read_at, :chat_message_id, :remote_actor_id])
    |> validate_length(:origin_domain, max: 255)
    |> foreign_key_constraint(:chat_message_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint([:chat_message_id, :remote_actor_id],
      name: :messaging_federation_read_receipts_unique
    )
  end
end
