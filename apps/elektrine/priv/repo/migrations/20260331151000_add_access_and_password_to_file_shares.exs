defmodule Elektrine.Repo.Migrations.AddAccessAndPasswordToFileShares do
  use Ecto.Migration

  def change do
    alter table(:file_shares) do
      add :access_level, :string, null: false, default: "download"
      add :password_hash, :text
    end

    create index(:file_shares, [:access_level])
  end
end
