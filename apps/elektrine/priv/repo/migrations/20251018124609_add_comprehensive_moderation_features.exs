defmodule Elektrine.Repo.Migrations.AddComprehensiveModerationFeatures do
  use Ecto.Migration

  def change do
    # ===== Thread Locking =====
    alter table(:messages) do
      add :locked_at, :utc_datetime
      add :locked_by_id, references(:users, on_delete: :nilify_all)
      add :lock_reason, :text
      # "pending", "approved", "rejected"
      add :approval_status, :string
      add :approved_by_id, references(:users, on_delete: :nilify_all)
      add :approved_at, :utc_datetime
    end

    create index(:messages, [:locked_at])
    create index(:messages, [:locked_by_id])
    create index(:messages, [:approval_status])

    # ===== Community Settings =====
    alter table(:conversations) do
      # 0 = disabled
      add :slow_mode_seconds, :integer, default: 0
      add :approval_mode_enabled, :boolean, default: false
      # Auto-approve after X posts
      add :approval_threshold_posts, :integer, default: 3
    end

    # ===== User Warnings =====
    create table(:user_warnings) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :warned_by_id, references(:users, on_delete: :nilify_all), null: false
      add :reason, :text, null: false
      # "low", "medium", "high"
      add :severity, :string, default: "low"
      add :acknowledged_at, :utc_datetime
      add :related_message_id, references(:messages, on_delete: :nilify_all)

      timestamps(updated_at: false)
    end

    create index(:user_warnings, [:conversation_id, :user_id])
    create index(:user_warnings, [:user_id])
    create index(:user_warnings, [:warned_by_id])

    # ===== Moderator Notes =====
    create table(:moderator_notes) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :target_user_id, references(:users, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, on_delete: :nilify_all), null: false
      add :note, :text, null: false
      add :is_important, :boolean, default: false

      timestamps(updated_at: false)
    end

    create index(:moderator_notes, [:conversation_id, :target_user_id])
    create index(:moderator_notes, [:target_user_id])
    create index(:moderator_notes, [:created_by_id])

    # ===== Auto-Moderation Rules =====
    create table(:auto_mod_rules) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :name, :string, null: false
      # "keyword", "regex", "link_domain", "spam_pattern"
      add :rule_type, :string, null: false
      add :pattern, :text, null: false
      # "flag", "remove", "hold_for_review"
      add :action, :string, null: false
      add :enabled, :boolean, default: true
      add :created_by_id, references(:users, on_delete: :nilify_all), null: false

      timestamps()
    end

    create index(:auto_mod_rules, [:conversation_id])
    create index(:auto_mod_rules, [:enabled])

    # ===== Enhance existing moderation_actions table =====
    alter table(:moderation_actions) do
      add :target_message_id, references(:messages, on_delete: :nilify_all)
    end

    create index(:moderation_actions, [:target_message_id])

    # ===== Post Rate Limiting (for slow mode) =====
    create table(:user_post_timestamps) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :last_post_at, :utc_datetime, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:user_post_timestamps, [:conversation_id, :user_id])
    create index(:user_post_timestamps, [:last_post_at])
  end
end
