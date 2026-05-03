defmodule Elektrine.Messaging.ChatConversationEncryptionKey do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_conversation_encryption_keys" do
    field :key_uid, :string
    field :algorithm, :string, default: "AES-256-GCM"
    field :active, :boolean, default: true
    field :metadata, :map, default: %{}

    belongs_to :conversation, Elektrine.Messaging.ChatConversation
    belongs_to :created_by, Elektrine.Accounts.User

    has_many :recipients, Elektrine.Messaging.ChatConversationKeyRecipient,
      foreign_key: :conversation_key_id

    timestamps()
  end

  def changeset(encryption_key, attrs) do
    encryption_key
    |> cast(attrs, [:conversation_id, :key_uid, :created_by_id, :algorithm, :active, :metadata])
    |> validate_required([:conversation_id, :key_uid, :algorithm])
    |> validate_length(:key_uid, min: 12, max: 128)
    |> validate_inclusion(:algorithm, ["AES-256-GCM"])
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:created_by_id)
    |> unique_constraint([:conversation_id, :key_uid])
  end
end
