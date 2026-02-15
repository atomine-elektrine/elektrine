defmodule Elektrine.Repo.Migrations.AddMediaMetadataToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :media_metadata, :map, default: %{}
    end
  end
end
