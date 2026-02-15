defmodule Elektrine.Repo.Migrations.AddMessagingFederationEventStreamTables do
  use Ecto.Migration

  def change do
    create table(:messaging_federation_events) do
      add :event_id, :string, null: false
      add :origin_domain, :string, null: false
      add :event_type, :string, null: false
      add :stream_id, :string, null: false
      add :sequence, :bigint, null: false
      add :payload, :map, null: false
      add :received_at, :utc_datetime, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:messaging_federation_events, [:event_id])
    create index(:messaging_federation_events, [:origin_domain, :stream_id, :sequence])
    create index(:messaging_federation_events, [:inserted_at])

    create table(:messaging_federation_stream_positions) do
      add :origin_domain, :string, null: false
      add :stream_id, :string, null: false
      add :last_sequence, :bigint, null: false, default: 0

      timestamps()
    end

    create unique_index(:messaging_federation_stream_positions, [:origin_domain, :stream_id],
             name: :messaging_federation_stream_positions_unique
           )

    create table(:messaging_federation_stream_counters) do
      add :stream_id, :string, null: false
      add :next_sequence, :bigint, null: false, default: 1

      timestamps()
    end

    create unique_index(:messaging_federation_stream_counters, [:stream_id],
             name: :messaging_federation_stream_counters_unique
           )
  end
end
