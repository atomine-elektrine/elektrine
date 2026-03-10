defmodule Elektrine.Repo.Migrations.CreateMessagingFederationInviteStates do
  use Ecto.Migration

  def change do
    create table(:messaging_federation_invite_states) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :origin_domain, :string, null: false
      add :actor_uri, :string, null: false
      add :actor_payload, :map, null: false, default: %{}
      add :target_uri, :string, null: false
      add :target_payload, :map, null: false, default: %{}
      add :role, :string, null: false
      add :state, :string, null: false
      add :invited_at_remote, :utc_datetime
      add :updated_at_remote, :utc_datetime, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :messaging_federation_invite_states,
             [:conversation_id, :target_uri],
             name: :messaging_federation_invite_states_unique
           )

    create index(
             :messaging_federation_invite_states,
             [:origin_domain],
             name: :messaging_federation_invite_states_origin_idx
           )
  end
end
