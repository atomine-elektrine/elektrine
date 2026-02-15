defmodule Elektrine.Repo.Migrations.AddMessagingFederationOutboxAndArchive do
  use Ecto.Migration

  def change do
    create table(:messaging_federation_outbox_events) do
      add :event_id, :string, null: false
      add :event_type, :string, null: false
      add :stream_id, :string, null: false
      add :sequence, :bigint, null: false
      add :payload, :map, null: false
      add :target_domains, {:array, :string}, null: false, default: []
      add :delivered_domains, {:array, :string}, null: false, default: []
      add :attempt_count, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 8
      add :status, :string, null: false, default: "pending"
      add :next_retry_at, :utc_datetime, null: false
      add :last_error, :text

      add :partition_month, :date,
        null: false,
        default: fragment("date_trunc('month', now())::date")

      add :dispatched_at, :utc_datetime

      timestamps()
    end

    create unique_index(:messaging_federation_outbox_events, [:event_id],
             name: :messaging_federation_outbox_event_id_unique
           )

    create index(:messaging_federation_outbox_events, [:status, :next_retry_at],
             name: :messaging_federation_outbox_status_retry_idx
           )

    create index(:messaging_federation_outbox_events, [:partition_month],
             name: :messaging_federation_outbox_partition_month_idx
           )

    create table(:messaging_federation_events_archive) do
      add :event_id, :string, null: false
      add :origin_domain, :string, null: false
      add :event_type, :string, null: false
      add :stream_id, :string, null: false
      add :sequence, :bigint, null: false
      add :payload, :map, null: false
      add :received_at, :utc_datetime, null: false
      add :partition_month, :date, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:messaging_federation_events_archive, [:event_id],
             name: :messaging_federation_events_archive_event_id_unique
           )

    create index(:messaging_federation_events_archive, [:partition_month],
             name: :messaging_federation_events_archive_partition_month_idx
           )

    create index(:messaging_federation_events_archive, [:origin_domain, :stream_id, :sequence],
             name: :messaging_federation_events_archive_stream_seq_idx
           )
  end
end
