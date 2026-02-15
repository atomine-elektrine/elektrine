defmodule Elektrine.Repo.Migrations.CreateDeviceTokens do
  use Ecto.Migration

  def change do
    create table(:device_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :string, null: false
      # "ios" or "android"
      add :platform, :string, null: false
      add :app_version, :string
      add :device_name, :string
      add :device_model, :string
      add :os_version, :string
      add :bundle_id, :string
      add :enabled, :boolean, default: true
      add :last_used_at, :utc_datetime
      add :failed_count, :integer, default: 0
      add :last_error, :string

      timestamps()
    end

    create unique_index(:device_tokens, [:token])
    create index(:device_tokens, [:user_id])
    create index(:device_tokens, [:platform])
    create index(:device_tokens, [:enabled])
  end
end
