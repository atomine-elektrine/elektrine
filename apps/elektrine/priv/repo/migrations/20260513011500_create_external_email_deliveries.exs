defmodule Elektrine.Repo.Migrations.CreateExternalEmailDeliveries do
  use Ecto.Migration

  def change do
    create table(:external_email_deliveries) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :mailbox_id, references(:email_mailboxes, on_delete: :delete_all), null: false
      add :sent_message_id, references(:email_messages, on_delete: :delete_all), null: false
      add :envelope_from, :string, null: false
      add :to, {:array, :string}, null: false, default: []
      add :cc, {:array, :string}, null: false, default: []
      add :bcc, {:array, :string}, null: false, default: []
      add :params, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :provider, :string
      add :provider_message_id, :string
      add :error, :text
      add :last_attempted_at, :utc_datetime
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:external_email_deliveries, [:sent_message_id])
    create index(:external_email_deliveries, [:user_id, :status])
    create index(:external_email_deliveries, [:mailbox_id, :status])
  end
end
