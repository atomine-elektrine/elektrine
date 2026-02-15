defmodule Elektrine.Repo.Migrations.CreateDataExports do
  use Ecto.Migration

  def change do
    create table(:data_exports) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :export_type, :string, null: false
      add :format, :string, null: false, default: "json"
      add :status, :string, null: false, default: "pending"
      add :file_path, :string
      add :file_size, :bigint
      add :item_count, :integer
      add :filters, :map, default: %{}
      add :download_token, :string
      add :download_count, :integer, default: 0
      add :expires_at, :utc_datetime
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :error, :text

      timestamps()
    end

    create index(:data_exports, [:user_id])
    create index(:data_exports, [:user_id, :status])
    create index(:data_exports, [:download_token])
    create index(:data_exports, [:expires_at])
  end
end
