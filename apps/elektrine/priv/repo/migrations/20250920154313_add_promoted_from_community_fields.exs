defmodule Elektrine.Repo.Migrations.AddPromotedFromCommunityFields do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :promoted_from_community_name, :string
      add :promoted_from_community_hash, :string
    end
  end
end
