defmodule Elektrine.Repo.Migrations.CreateEmailThreads do
  use Ecto.Migration

  def change do
    create table(:email_threads) do
      add :mailbox_id, references(:mailboxes, on_delete: :delete_all), null: false
      add :subject_hash, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:email_threads, [:mailbox_id])
    create unique_index(:email_threads, [:mailbox_id, :subject_hash])
  end
end
