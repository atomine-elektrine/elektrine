defmodule Elektrine.Repo.Migrations.AddPgpWkdHashToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :pgp_wkd_hash, :string
    end

    # Create index for efficient WKD lookups
    create index(:users, [:pgp_wkd_hash], where: "pgp_wkd_hash IS NOT NULL")
  end
end
