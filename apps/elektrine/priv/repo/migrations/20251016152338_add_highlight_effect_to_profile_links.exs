defmodule Elektrine.Repo.Migrations.AddHighlightEffectToProfileLinks do
  use Ecto.Migration

  def change do
    alter table(:profile_links) do
      add :highlight_effect, :string
    end
  end
end
