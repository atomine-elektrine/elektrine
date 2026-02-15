defmodule Elektrine.Repo.Migrations.AddBackgroundJobTables do
  use Ecto.Migration

  def change do
    # Email send jobs queue
    create table(:email_jobs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # pending, processing, completed, failed
      add :status, :string, default: "pending"
      # to, subject, body, etc.
      add :email_attrs, :map, null: false
      # attachment metadata
      add :attachments, :map
      add :attempts, :integer, default: 0
      add :max_attempts, :integer, default: 3
      add :error, :string
      add :completed_at, :utc_datetime
      # for delayed sending
      add :scheduled_for, :utc_datetime

      timestamps()
    end

    create index(:email_jobs, [:status])
    create index(:email_jobs, [:user_id])
    create index(:email_jobs, [:status, :scheduled_for], where: "status = 'pending'")

    # Link preview fetch jobs queue
    create table(:link_preview_jobs) do
      add :url, :string, null: false
      # pending, processing, completed, failed
      add :status, :string, default: "pending"
      add :message_id, references(:messages, on_delete: :delete_all)
      add :attempts, :integer, default: 0
      add :max_attempts, :integer, default: 3
      add :error, :string
      add :link_preview_id, references(:link_previews, on_delete: :nilify_all)
      add :completed_at, :utc_datetime

      timestamps()
    end

    create index(:link_preview_jobs, [:status])
    create index(:link_preview_jobs, [:url])
    create index(:link_preview_jobs, [:message_id])

    create index(:link_preview_jobs, [:status, :attempts],
             where: "status = 'pending' AND attempts < 3"
           )
  end
end
