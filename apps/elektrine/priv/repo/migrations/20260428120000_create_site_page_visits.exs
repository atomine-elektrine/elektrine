defmodule Elektrine.Repo.Migrations.CreateSitePageVisits do
  use Ecto.Migration

  def change do
    create table(:site_page_visits) do
      add :viewer_user_id, references(:users, on_delete: :nilify_all)
      add :visitor_id, :string
      add :ip_address, :string
      add :user_agent, :text
      add :referer, :text
      add :request_host, :string, null: false
      add :request_path, :text, null: false
      add :status, :integer, null: false

      timestamps(updated_at: false)
    end

    create index(:site_page_visits, [:request_host])
    create index(:site_page_visits, [:inserted_at])
    create index(:site_page_visits, [:request_host, :inserted_at])
    create index(:site_page_visits, [:viewer_user_id])
  end
end
