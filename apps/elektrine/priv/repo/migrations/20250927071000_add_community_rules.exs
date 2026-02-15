defmodule Elektrine.Repo.Migrations.AddCommunityRules do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :community_rules, :text
    end
  end
end
