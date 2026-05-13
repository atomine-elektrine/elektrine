defmodule Elektrine.Repo.Migrations.CreateInternalEmailDeliveries do
  use Ecto.Migration

  def change do
    create table(:internal_email_deliveries) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :mailbox_id, references(:email_mailboxes, on_delete: :delete_all), null: false
      add :sent_message_id, references(:email_messages, on_delete: :delete_all), null: false

      add :recipient_mailbox_id, references(:email_mailboxes, on_delete: :delete_all), null: false

      add :delivered_message_id, references(:email_messages, on_delete: :nilify_all)
      add :recipient, :string, null: false
      add :recipient_type, :string, null: false, default: "to"
      add :params, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :error, :text
      add :last_attempted_at, :utc_datetime
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :internal_email_deliveries,
             [:sent_message_id, :recipient_type, :recipient],
             name: :internal_email_deliveries_recipient_unique
           )

    create index(:internal_email_deliveries, [:user_id, :status])
    create index(:internal_email_deliveries, [:mailbox_id, :status])
    create index(:internal_email_deliveries, [:recipient_mailbox_id, :status])
    create index(:internal_email_deliveries, [:sent_message_id])

    create table(:internal_email_delivery_attempts) do
      add :delivery_id, references(:internal_email_deliveries, on_delete: :delete_all),
        null: false

      add :attempt, :integer, null: false
      add :status, :string, null: false
      add :delivered_message_id, references(:email_messages, on_delete: :nilify_all)
      add :error, :text
      add :metadata, :map, null: false, default: %{}
      add :attempted_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:internal_email_delivery_attempts, [:delivery_id, :attempt])
    create index(:internal_email_delivery_attempts, [:status])
  end
end
