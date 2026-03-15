defmodule Elektrine.Repo.Migrations.CreateJmapEmailTombstones do
  use Ecto.Migration

  def change do
    create table(:jmap_email_tombstones) do
      add :mailbox_id, references(:mailboxes, on_delete: :delete_all), null: false
      add :email_id, :bigint, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:jmap_email_tombstones, [:mailbox_id, :inserted_at])
    create index(:jmap_email_tombstones, [:mailbox_id, :email_id])
  end
end
