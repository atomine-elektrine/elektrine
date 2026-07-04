defmodule Elektrine.Repo.Migrations.CreateChatWebhooks do
  use Ecto.Migration

  def change do
    create table(:chat_webhooks) do
      add :conversation_id, references(:chat_conversations, on_delete: :delete_all), null: false
      add :creator_id, references(:users, on_delete: :nilify_all)
      add :name, :string, null: false
      add :avatar_url, :string
      add :token_hash, :string, null: false
      add :active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:chat_webhooks, [:token_hash])
    create index(:chat_webhooks, [:conversation_id])
    create index(:chat_webhooks, [:creator_id])
  end
end
