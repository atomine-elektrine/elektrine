defmodule Elektrine.Repo.Migrations.AddFaviconAndTitleToProfiles do
  use Ecto.Migration

  def change do
    alter table(:user_profiles) do
      add :page_title, :string
      add :favicon_url, :string
    end
  end
end
