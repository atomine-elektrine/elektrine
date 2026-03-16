defmodule Elektrine.Repo.Migrations.CreateMessagingFederationCallSessions do
  use Ecto.Migration

  def change do
    create table(:messaging_federation_call_sessions) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :local_user_id, references(:users, on_delete: :delete_all), null: false
      add :federated_call_id, :string, null: false
      add :origin_domain, :string, null: false
      add :remote_domain, :string, null: false
      add :remote_handle, :string, null: false
      add :remote_actor, :map, null: false, default: %{}
      add :call_type, :string, null: false
      add :direction, :string, null: false
      add :status, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :started_at_remote, :utc_datetime
      add :ended_at_remote, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :messaging_federation_call_sessions,
             [:local_user_id, :federated_call_id],
             name: :messaging_federation_call_sessions_user_call_unique
           )

    create index(
             :messaging_federation_call_sessions,
             [:conversation_id, :inserted_at],
             name: :messaging_federation_call_sessions_conversation_inserted_at_idx
           )

    create index(
             :messaging_federation_call_sessions,
             [:remote_domain, :status],
             name: :messaging_federation_call_sessions_remote_domain_status_idx
           )
  end
end
