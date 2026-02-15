defmodule Elektrine.Repo.Migrations.AddModerationSystem do
  use Ecto.Migration

  def change do
    create table(:user_timeouts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: true
      add :timeout_until, :utc_datetime, null: false
      add :reason, :string
      add :created_by_id, references(:users, on_delete: :nilify_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:user_timeouts, [:user_id])
    create index(:user_timeouts, [:conversation_id])
    create index(:user_timeouts, [:timeout_until])

    create table(:moderation_actions) do
      add :action_type, :string, null: false
      add :target_user_id, references(:users, on_delete: :delete_all), null: false
      add :moderator_id, references(:users, on_delete: :delete_all), null: false
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: true
      add :reason, :string
      add :duration, :integer
      add :details, :map

      timestamps(type: :utc_datetime)
    end

    create index(:moderation_actions, [:target_user_id])
    create index(:moderation_actions, [:moderator_id])
    create index(:moderation_actions, [:conversation_id])
    create index(:moderation_actions, [:action_type])
  end
end
