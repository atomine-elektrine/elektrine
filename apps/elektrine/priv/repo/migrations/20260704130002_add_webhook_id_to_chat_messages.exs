defmodule Elektrine.Repo.Migrations.AddWebhookIdToChatMessages do
  use Ecto.Migration

  def change do
    alter table(:chat_messages) do
      add :webhook_id, references(:chat_webhooks, on_delete: :nilify_all)
    end

    create index(:chat_messages, [:webhook_id])
  end
end
