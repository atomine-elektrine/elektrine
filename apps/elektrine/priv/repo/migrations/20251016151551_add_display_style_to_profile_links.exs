defmodule Elektrine.Repo.Migrations.AddDisplayStyleToProfileLinks do
  use Ecto.Migration

  def change do
    alter table(:profile_links) do
      add :display_style, :string
    end
  end
end
