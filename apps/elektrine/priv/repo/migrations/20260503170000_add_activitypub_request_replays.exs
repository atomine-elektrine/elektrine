defmodule Elektrine.Repo.Migrations.AddActivitypubRequestReplays do
  use Ecto.Migration

  def change do
    create table(:activitypub_request_replays) do
      add :nonce, :string, null: false
      add :key_id, :string, null: false
      add :actor_uri, :string
      add :http_method, :string, null: false
      add :request_path, :string, null: false
      add :query_string, :string
      add :signature_timestamp, :string
      add :digest, :string
      add :seen_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:activitypub_request_replays, [:nonce],
             name: :activitypub_request_replays_nonce_unique
           )

    create index(:activitypub_request_replays, [:expires_at],
             name: :activitypub_request_replays_expires_at_idx
           )

    create index(:activitypub_request_replays, [:actor_uri, :inserted_at],
             name: :activitypub_request_replays_actor_inserted_idx
           )
  end
end
