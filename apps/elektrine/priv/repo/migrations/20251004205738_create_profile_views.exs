defmodule Elektrine.Repo.Migrations.CreateProfileViews do
  use Ecto.Migration

  def change do
    create table(:profile_views) do
      add :profile_user_id, references(:users, on_delete: :delete_all), null: false
      add :viewer_user_id, references(:users, on_delete: :delete_all), null: true
      add :viewer_session_id, :string, null: true
      add :ip_address, :string
      add :user_agent, :text
      add :referer, :text

      timestamps(updated_at: false)
    end

    create index(:profile_views, [:profile_user_id])
    create index(:profile_views, [:viewer_user_id])
    create index(:profile_views, [:viewer_session_id])
    create index(:profile_views, [:profile_user_id, :inserted_at])
    create index(:profile_views, [:profile_user_id, :viewer_user_id, :inserted_at])
    create index(:profile_views, [:profile_user_id, :viewer_session_id, :inserted_at])
  end
end
