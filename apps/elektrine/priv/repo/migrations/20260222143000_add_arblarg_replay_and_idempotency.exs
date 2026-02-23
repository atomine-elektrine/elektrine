defmodule Elektrine.Repo.Migrations.AddArblargReplayAndIdempotency do
  use Ecto.Migration

  def up do
    alter table(:messaging_federation_events) do
      add :protocol_version, :string, null: false, default: "1.0"
      add :idempotency_key, :string
    end

    execute(
      "UPDATE messaging_federation_events SET idempotency_key = event_id WHERE idempotency_key IS NULL",
      ""
    )

    alter table(:messaging_federation_events) do
      modify :idempotency_key, :string, null: false
    end

    create unique_index(
             :messaging_federation_events,
             [:origin_domain, :idempotency_key],
             name: :messaging_federation_events_origin_idempotency_unique
           )

    alter table(:messaging_federation_events_archive) do
      add :protocol_version, :string, null: false, default: "1.0"
      add :idempotency_key, :string
    end

    execute(
      "UPDATE messaging_federation_events_archive SET idempotency_key = event_id WHERE idempotency_key IS NULL",
      ""
    )

    alter table(:messaging_federation_events_archive) do
      modify :idempotency_key, :string, null: false
    end

    create index(
             :messaging_federation_events_archive,
             [:origin_domain, :idempotency_key],
             name: :messaging_federation_events_archive_origin_idempotency_idx
           )

    create table(:messaging_federation_request_replays) do
      add :nonce, :string, null: false
      add :origin_domain, :string, null: false
      add :key_id, :string
      add :http_method, :string, null: false
      add :request_path, :string, null: false
      add :timestamp, :bigint, null: false
      add :seen_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:messaging_federation_request_replays, [:nonce],
             name: :messaging_federation_request_replays_nonce_unique
           )

    create index(:messaging_federation_request_replays, [:expires_at],
             name: :messaging_federation_request_replays_expires_at_idx
           )

    create index(:messaging_federation_request_replays, [:origin_domain, :inserted_at],
             name: :messaging_federation_request_replays_origin_inserted_idx
           )
  end

  def down do
    drop_if_exists index(:messaging_federation_request_replays, [:origin_domain, :inserted_at],
                     name: :messaging_federation_request_replays_origin_inserted_idx
                   )

    drop_if_exists index(:messaging_federation_request_replays, [:expires_at],
                     name: :messaging_federation_request_replays_expires_at_idx
                   )

    drop_if_exists index(:messaging_federation_request_replays, [:nonce],
                     name: :messaging_federation_request_replays_nonce_unique
                   )

    drop table(:messaging_federation_request_replays)

    drop_if_exists index(:messaging_federation_events_archive, [:origin_domain, :idempotency_key],
                     name: :messaging_federation_events_archive_origin_idempotency_idx
                   )

    alter table(:messaging_federation_events_archive) do
      remove :idempotency_key
      remove :protocol_version
    end

    drop_if_exists index(:messaging_federation_events, [:origin_domain, :idempotency_key],
                     name: :messaging_federation_events_origin_idempotency_unique
                   )

    alter table(:messaging_federation_events) do
      remove :idempotency_key
      remove :protocol_version
    end
  end
end
