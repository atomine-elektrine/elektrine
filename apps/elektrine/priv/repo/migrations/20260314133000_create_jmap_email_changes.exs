defmodule Elektrine.Repo.Migrations.CreateJmapEmailChanges do
  use Ecto.Migration

  def change do
    create table(:jmap_email_changes) do
      add :mailbox_id, references(:mailboxes, on_delete: :delete_all), null: false
      add :email_id, :bigint, null: false
      add :change_type, :string, null: false
      add :state_counter, :bigint, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:jmap_email_changes, [:mailbox_id, :state_counter])
    create index(:jmap_email_changes, [:mailbox_id, :email_id, :state_counter])
  end
end
