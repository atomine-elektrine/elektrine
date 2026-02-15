defmodule Elektrine.Repo.Migrations.AddEmailFeatures do
  use Ecto.Migration

  def change do
    # 1. Blocked Senders table
    create table(:email_blocked_senders) do
      add :email, :string
      add :domain, :string
      add :reason, :string
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:email_blocked_senders, [:user_id])
    create index(:email_blocked_senders, [:email])
    create index(:email_blocked_senders, [:domain])
    create unique_index(:email_blocked_senders, [:user_id, :email], where: "email IS NOT NULL")
    create unique_index(:email_blocked_senders, [:user_id, :domain], where: "domain IS NOT NULL")

    # 2. Safe Senders (Whitelist) table
    create table(:email_safe_senders) do
      add :email, :string
      add :domain, :string
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:email_safe_senders, [:user_id])
    create index(:email_safe_senders, [:email])
    create index(:email_safe_senders, [:domain])
    create unique_index(:email_safe_senders, [:user_id, :email], where: "email IS NOT NULL")
    create unique_index(:email_safe_senders, [:user_id, :domain], where: "domain IS NOT NULL")

    # 3. Email Filters/Rules table
    create table(:email_filters) do
      add :name, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :priority, :integer, default: 0, null: false
      add :stop_processing, :boolean, default: false, null: false

      # Conditions (JSON)
      add :conditions, :map, default: %{}, null: false

      # Actions (JSON)
      add :actions, :map, default: %{}, null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:email_filters, [:user_id])
    create index(:email_filters, [:enabled])
    create index(:email_filters, [:priority])

    # 4. Auto-reply settings table
    create table(:email_auto_replies) do
      add :enabled, :boolean, default: false, null: false
      add :subject, :string
      add :body, :text, null: false
      add :html_body, :text
      add :start_date, :date
      add :end_date, :date
      add :only_contacts, :boolean, default: false, null: false
      add :exclude_mailing_lists, :boolean, default: true, null: false
      add :reply_once_per_sender, :boolean, default: true, null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:email_auto_replies, [:user_id])

    # 5. Auto-reply tracking (to implement reply_once_per_sender)
    create table(:email_auto_reply_log) do
      add :sender_email, :string, null: false
      add :sent_at, :utc_datetime, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
    end

    create index(:email_auto_reply_log, [:user_id])
    create index(:email_auto_reply_log, [:sender_email])
    create index(:email_auto_reply_log, [:sent_at])
    create unique_index(:email_auto_reply_log, [:user_id, :sender_email])

    # 6. Email Templates table
    create table(:email_templates) do
      add :name, :string, null: false
      add :subject, :string
      add :body, :text, null: false
      add :html_body, :text
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:email_templates, [:user_id])
    create unique_index(:email_templates, [:user_id, :name])

    # 7. Custom Folders table
    create table(:email_folders) do
      add :name, :string, null: false
      add :color, :string
      add :icon, :string
      add :parent_id, references(:email_folders, on_delete: :nilify_all)
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:email_folders, [:user_id])
    create index(:email_folders, [:parent_id])
    create unique_index(:email_folders, [:user_id, :name])

    # 8. Labels/Tags table
    create table(:email_labels) do
      add :name, :string, null: false
      add :color, :string, default: "#3b82f6"
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:email_labels, [:user_id])
    create unique_index(:email_labels, [:user_id, :name])

    # 9. Message-Label junction table
    create table(:email_message_labels, primary_key: false) do
      add :message_id, references(:email_messages, on_delete: :delete_all), null: false
      add :label_id, references(:email_labels, on_delete: :delete_all), null: false
    end

    create unique_index(:email_message_labels, [:message_id, :label_id])
    create index(:email_message_labels, [:label_id])

    # 10. Add priority/importance and other fields to email_messages
    alter table(:email_messages) do
      add :priority, :string, default: "normal"
      add :folder_id, references(:email_folders, on_delete: :nilify_all)
      add :scheduled_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :undo_send_until, :utc_datetime
    end

    create index(:email_messages, [:priority])
    create index(:email_messages, [:folder_id])
    create index(:email_messages, [:scheduled_at])
    create index(:email_messages, [:expires_at])

    # 11. Email exports tracking table
    create table(:email_exports) do
      add :status, :string, default: "pending", null: false
      add :format, :string, default: "mbox", null: false
      add :file_path, :string
      add :file_size, :integer
      add :message_count, :integer
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :error, :text
      add :filters, :map, default: %{}
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:email_exports, [:user_id])
    create index(:email_exports, [:status])
  end
end
