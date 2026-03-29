defmodule Elektrine.Repo.Migrations.AddDnssecAndMailHardeningFieldsToDnsRecords do
  use Ecto.Migration

  def change do
    alter table(:dns_records) do
      add :protocol, :integer
      add :algorithm, :integer
      add :key_tag, :integer
      add :digest_type, :integer
      add :usage, :integer
      add :selector, :integer
      add :matching_type, :integer
    end
  end
end
