defmodule Elektrine.Repo.Migrations.CreateApprovedSenders do
  use Ecto.Migration

  def change do
    create table(:approved_senders) do
      add :email_address, :string, null: false
      add :mailbox_id, references(:mailboxes, on_delete: :delete_all), null: false
      add :approved_at, :utc_datetime, null: false
      add :last_email_at, :utc_datetime
      add :email_count, :integer, default: 0
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:approved_senders, [:email_address, :mailbox_id])
    create index(:approved_senders, [:mailbox_id])
    create index(:approved_senders, [:email_address])
  end
end
