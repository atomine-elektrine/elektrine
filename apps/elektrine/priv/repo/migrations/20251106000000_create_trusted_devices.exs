defmodule Elektrine.Repo.Migrations.CreateTrustedDevices do
  use Ecto.Migration

  def change do
    create table(:trusted_devices) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :device_token, :string, null: false
      add :device_name, :string
      add :user_agent, :string
      add :ip_address, :string
      add :last_used_at, :utc_datetime
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:trusted_devices, [:user_id])
    create unique_index(:trusted_devices, [:device_token])
    create index(:trusted_devices, [:expires_at])
  end
end
