defmodule Elektrine.Repo.Migrations.DropNotesTables do
  use Ecto.Migration

  def up do
    drop_if_exists table(:note_shares)
    drop_if_exists table(:notes)
  end

  def down do
    create table(:notes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :title, :text
      add :body, :text, null: false, default: ""
      add :pinned, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:notes, [:user_id])
    create index(:notes, [:user_id, :pinned])
    create index(:notes, [:user_id, :updated_at])

    create table(:note_shares) do
      add :note_id, references(:notes, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :token_hash, :string, null: false
      add :encrypted_payload, :map
      add :expires_at, :utc_datetime
      add :burn_after_read, :boolean, null: false, default: false
      add :revoked_at, :utc_datetime
      add :view_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:note_shares, [:token])
    create unique_index(:note_shares, [:token_hash])
    create index(:note_shares, [:note_id])
    create index(:note_shares, [:user_id, :note_id])
    create index(:note_shares, [:expires_at])
  end
end
