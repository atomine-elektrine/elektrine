defmodule Elektrine.Repo.Migrations.AddThumbnailUrlToProfileLinks do
  use Ecto.Migration

  def change do
    alter table(:profile_links) do
      add :thumbnail_url, :string
    end
  end
end
