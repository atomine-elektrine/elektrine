defmodule Elektrine.Repo.Migrations.AddSiteSessions do
  use Ecto.Migration

  def change do
    create table(:site_sessions) do
      add :session_id, :string, null: false
      add :viewer_user_id, references(:users, on_delete: :nilify_all)
      add :visitor_id, :string
      add :ip_address, :string
      add :user_agent, :text
      add :referer, :text
      add :entry_host, :string, null: false
      add :entry_path, :text, null: false
      add :exit_host, :string, null: false
      add :exit_path, :text, null: false
      add :page_views, :integer, null: false, default: 1
      add :started_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
      add :duration_seconds, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:site_sessions, [:session_id])
    create index(:site_sessions, [:entry_host])
    create index(:site_sessions, [:started_at])
    create index(:site_sessions, [:entry_host, :started_at])
    create index(:site_sessions, [:viewer_user_id])

    alter table(:site_page_visits) do
      add :session_id, :string
    end

    create index(:site_page_visits, [:session_id])
  end
end
