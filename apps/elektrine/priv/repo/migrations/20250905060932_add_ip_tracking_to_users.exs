defmodule Elektrine.Repo.Migrations.AddIpTrackingToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :registration_ip, :text
      add :last_login_ip, :text
      add :last_login_at, :utc_datetime
      add :login_count, :integer, default: 0
    end

    # Create indexes for better performance on IP lookups
    create index(:users, [:registration_ip])
    create index(:users, [:last_login_ip])
    create index(:users, [:last_login_at])
  end
end
