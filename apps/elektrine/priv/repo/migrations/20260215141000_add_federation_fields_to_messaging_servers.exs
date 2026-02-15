defmodule Elektrine.Repo.Migrations.AddFederationFieldsToMessagingServers do
  use Ecto.Migration

  def change do
    alter table(:messaging_servers) do
      add :last_federated_at, :utc_datetime
      add :federation_id, :string
      add :origin_domain, :string
      add :is_federated_mirror, :boolean, default: false, null: false
    end

    create index(:messaging_servers, [:origin_domain])

    create unique_index(:messaging_servers, [:federation_id],
             where: "federation_id IS NOT NULL",
             name: :messaging_servers_federation_id_unique
           )

    create unique_index(:conversations, [:federated_source],
             where: "type = 'channel' AND federated_source IS NOT NULL",
             name: :conversations_channel_federated_source_unique
           )

    alter table(:chat_messages) do
      add :federated_source, :string
      add :origin_domain, :string
      add :is_federated_mirror, :boolean, default: false, null: false
    end

    create index(:chat_messages, [:origin_domain])

    create unique_index(:chat_messages, [:conversation_id, :federated_source],
             where: "federated_source IS NOT NULL",
             name: :chat_messages_conversation_federated_source_unique
           )
  end
end
