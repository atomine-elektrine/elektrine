defmodule Elektrine.Repo.Migrations.AddExpirationToUserMutes do
  use Ecto.Migration

  def change do
    alter table(:user_mutes) do
      add :expires_at, :utc_datetime
    end

    create index(:user_mutes, [:expires_at])
  end
end
