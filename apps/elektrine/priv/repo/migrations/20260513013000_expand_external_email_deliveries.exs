defmodule Elektrine.Repo.Migrations.ExpandExternalEmailDeliveries do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:external_email_deliveries, [:sent_message_id])

    alter table(:external_email_deliveries) do
      add :recipient, :string
      add :recipient_type, :string, null: false, default: "to"
      add :domain, :string
      add :trace_id, :string
      add :response_code, :string
    end

    execute(
      "UPDATE external_email_deliveries SET recipient = COALESCE(\"to\"[1], cc[1], bcc[1]), domain = split_part(COALESCE(\"to\"[1], cc[1], bcc[1]), '@', 2), trace_id = 'legacy-' || id WHERE recipient IS NULL",
      "UPDATE external_email_deliveries SET recipient = NULL, domain = NULL, trace_id = NULL"
    )

    create unique_index(
             :external_email_deliveries,
             [:sent_message_id, :recipient_type, :recipient],
             name: :external_email_deliveries_recipient_unique
           )

    create index(:external_email_deliveries, [:domain, :status])
    create index(:external_email_deliveries, [:trace_id])

    create table(:external_email_delivery_attempts) do
      add :delivery_id, references(:external_email_deliveries, on_delete: :delete_all),
        null: false

      add :attempt, :integer, null: false
      add :status, :string, null: false
      add :provider, :string
      add :provider_message_id, :string
      add :response_code, :string
      add :error, :text
      add :metadata, :map, null: false, default: %{}
      add :attempted_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:external_email_delivery_attempts, [:delivery_id, :attempt])
    create index(:external_email_delivery_attempts, [:status])
  end
end
