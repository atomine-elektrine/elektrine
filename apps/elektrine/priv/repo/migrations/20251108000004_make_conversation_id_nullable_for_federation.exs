defmodule Elektrine.Repo.Migrations.MakeConversationIdNullableForFederation do
  use Ecto.Migration

  def change do
    # Make conversation_id and sender_id nullable to support federated messages
    # Federated messages use remote_actor_id instead
    alter table(:messages) do
      modify :conversation_id, :integer, null: true
      modify :sender_id, :integer, null: true
    end
  end
end
