defmodule Elektrine.Repo.Migrations.AddKairoContentAtRest do
  use Ecto.Migration

  def change do
    alter table(:kairo_sources) do
      add :content_encrypted, :map
    end
  end
end
