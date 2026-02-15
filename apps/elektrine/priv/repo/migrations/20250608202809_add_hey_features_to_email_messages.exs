defmodule Elektrine.Repo.Migrations.AddHeyFeaturesToEmailMessages do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      # The Screener - for new senders
      # pending, approved, rejected
      add :screener_status, :string, default: "pending"
      add :sender_approved, :boolean, default: false

      # Hey.com organization categories
      # inbox, feed, paper_trail, set_aside
      add :category, :string, default: "inbox"

      # Set Aside feature
      add :set_aside_at, :utc_datetime
      add :set_aside_reason, :string

      # Reply Later
      add :reply_later_at, :utc_datetime
      add :reply_later_reminder, :boolean, default: false

      # Paper Trail auto-categorization
      add :is_receipt, :boolean, default: false
      add :is_notification, :boolean, default: false
      add :is_newsletter, :boolean, default: false

      # Tracking
      add :opened_at, :utc_datetime
      add :first_opened_at, :utc_datetime
      add :open_count, :integer, default: 0
    end

    create index(:email_messages, [:screener_status])
    create index(:email_messages, [:category])
    create index(:email_messages, [:sender_approved])
    create index(:email_messages, [:set_aside_at])
    create index(:email_messages, [:reply_later_at])
    create index(:email_messages, [:is_receipt])
    create index(:email_messages, [:is_notification])
    create index(:email_messages, [:is_newsletter])
  end
end
