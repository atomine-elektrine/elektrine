defmodule Elektrine.Repo.Migrations.CreateChatMessages do
  use Ecto.Migration

  def change do
    create table(:chat_messages) do
      # Core fields
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :sender_id, references(:users, on_delete: :nilify_all)

      # Content - encrypted for privacy
      # Plaintext (cleared after encryption for DMs)
      add :content, :text
      # Encrypted content blob
      add :encrypted_content, :map
      # Searchable tokens
      add :search_index, {:array, :string}, default: []

      # Message metadata
      # text, image, file, voice, system
      add :message_type, :string, default: "text"
      add :media_urls, {:array, :string}, default: []
      # alt texts, dimensions, durations, etc.
      add :media_metadata, :map, default: %{}

      # Threading
      add :reply_to_id, references(:chat_messages, on_delete: :nilify_all)

      # State
      add :edited_at, :utc_datetime
      add :deleted_at, :utc_datetime

      # Voice message specific
      # Duration in seconds
      add :audio_duration, :integer
      add :audio_mime_type, :string

      timestamps()
    end

    # Primary index for fetching messages in a conversation
    create index(:chat_messages, [:conversation_id, :inserted_at])

    # Index for fetching messages by sender
    create index(:chat_messages, [:sender_id])

    # Index for replies
    create index(:chat_messages, [:reply_to_id])

    # Index for undeleted messages (partial index)
    create index(:chat_messages, [:conversation_id, :inserted_at],
             where: "deleted_at IS NULL",
             name: :chat_messages_active_idx
           )

    # Create chat_message_reactions table (separate from existing message_reactions)
    create table(:chat_message_reactions) do
      add :chat_message_id, references(:chat_messages, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all)
      add :emoji, :string, null: false

      timestamps()
    end

    create unique_index(:chat_message_reactions, [:chat_message_id, :user_id, :emoji],
             where: "user_id IS NOT NULL",
             name: :chat_message_reactions_user_unique
           )

    create unique_index(:chat_message_reactions, [:chat_message_id, :remote_actor_id, :emoji],
             where: "remote_actor_id IS NOT NULL",
             name: :chat_message_reactions_remote_unique
           )

    create index(:chat_message_reactions, [:chat_message_id])

    # Create chat_message_reads table for read receipts
    create table(:chat_message_reads, primary_key: false) do
      add :chat_message_id, references(:chat_messages, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :read_at, :utc_datetime, null: false
    end

    create unique_index(:chat_message_reads, [:chat_message_id, :user_id])
    create index(:chat_message_reads, [:user_id, :read_at])
  end
end
