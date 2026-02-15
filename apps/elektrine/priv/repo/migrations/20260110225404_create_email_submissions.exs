defmodule Elektrine.Repo.Migrations.CreateEmailSubmissions do
  use Ecto.Migration

  def change do
    create table(:email_submissions) do
      add :mailbox_id, references(:mailboxes, on_delete: :delete_all), null: false
      add :email_id, references(:email_messages, on_delete: :nilify_all)
      add :identity_id, :string, null: false
      add :envelope_from, :string, null: false
      add :envelope_to, {:array, :string}, null: false, default: []
      add :send_at, :utc_datetime
      add :undo_status, :string, default: "pending"
      add :delivery_status, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:email_submissions, [:mailbox_id])
    create index(:email_submissions, [:email_id])
  end
end
