defmodule Elektrine.Repo.Migrations.CreateProfileSiteVisits do
  use Ecto.Migration

  def change do
    create table(:profile_site_visits) do
      add :profile_user_id, references(:users, on_delete: :delete_all), null: false
      add :viewer_user_id, references(:users, on_delete: :nilify_all)
      add :visitor_id, :string
      add :ip_address, :string
      add :user_agent, :text
      add :referer, :text
      add :request_host, :string, null: false
      add :request_path, :text, null: false

      timestamps(updated_at: false)
    end

    create index(:profile_site_visits, [:profile_user_id])
    create index(:profile_site_visits, [:profile_user_id, :request_host])
    create index(:profile_site_visits, [:profile_user_id, :inserted_at])
    create index(:profile_site_visits, [:profile_user_id, :request_host, :inserted_at])
  end
end
