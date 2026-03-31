defmodule Elektrine.Repo.Migrations.AddExpiresAtToFileShares do
  use Ecto.Migration

  def change do
    alter table(:file_shares) do
      add :expires_at, :utc_datetime
    end

    create index(:file_shares, [:expires_at])
  end
end
