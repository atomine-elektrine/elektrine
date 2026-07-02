defmodule Elektrine.Repo.Migrations.CreateSuggestedAccountDismissals do
  use Ecto.Migration

  def change do
    create table(:suggested_account_dismissals) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :suggested_user_id, references(:users, on_delete: :delete_all), null: false
      add :dismissed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:suggested_account_dismissals, [:user_id])
    create index(:suggested_account_dismissals, [:suggested_user_id])

    create unique_index(:suggested_account_dismissals, [:user_id, :suggested_user_id])
  end
end
