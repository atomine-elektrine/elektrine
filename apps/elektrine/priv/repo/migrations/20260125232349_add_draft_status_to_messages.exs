defmodule Elektrine.Repo.Migrations.AddDraftStatusToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Draft status: nil = published, "draft" = draft
      add :is_draft, :boolean, default: false
      # Scheduled publishing time (optional, for future scheduling feature)
      add :scheduled_at, :utc_datetime
    end

    # Index for querying drafts by user
    create index(:messages, [:sender_id, :is_draft], where: "is_draft = true")
  end
end
