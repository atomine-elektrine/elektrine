defmodule Elektrine.Repo.Migrations.CreateReports do
  use Ecto.Migration

  def change do
    create table(:reports) do
      # Reporter info
      add :reporter_id, references(:users, on_delete: :delete_all), null: false

      # What is being reported (polymorphic)
      # "user", "message", "conversation", "post", etc.
      add :reportable_type, :string, null: false
      add :reportable_id, :integer, null: false

      # Report details
      # "spam", "harassment", "inappropriate", "violence", "hate_speech", "other"
      add :reason, :string, null: false
      add :description, :text
      add :screenshots, {:array, :string}, default: []

      # Status tracking
      # "pending", "reviewing", "resolved", "dismissed"
      add :status, :string, default: "pending"
      # "low", "normal", "high", "critical"
      add :priority, :string, default: "normal"

      # Admin handling
      add :reviewed_by_id, references(:users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime
      add :resolution_notes, :text
      # "warned", "suspended", "banned", "content_removed", "no_action"
      add :action_taken, :string

      # Additional metadata
      # Store additional context like URLs, conversation IDs, etc.
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:reports, [:reporter_id])
    create index(:reports, [:reportable_type, :reportable_id])
    create index(:reports, [:status])
    create index(:reports, [:priority])
    create index(:reports, [:reviewed_by_id])

    # Prevent duplicate reports from same user for same content
    create unique_index(:reports, [:reporter_id, :reportable_type, :reportable_id, :status],
             name: :reports_unique_pending_index,
             where: "status = 'pending'"
           )
  end
end
