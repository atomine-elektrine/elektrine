defmodule Elektrine.Repo.Migrations.CreateRejectedSenders do
  use Ecto.Migration

  def change do
    create table(:rejected_senders) do
      add :email_address, :string, null: false
      add :rejected_at, :utc_datetime, null: false
      add :rejection_count, :integer, default: 1
      add :last_rejection_at, :utc_datetime
      add :notes, :text

      add :mailbox_id, references(:mailboxes, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:rejected_senders, [:email_address, :mailbox_id])
    create index(:rejected_senders, [:mailbox_id])
  end
end
