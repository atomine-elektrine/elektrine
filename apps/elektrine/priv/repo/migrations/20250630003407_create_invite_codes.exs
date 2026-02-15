defmodule Elektrine.Repo.Migrations.CreateInviteCodes do
  use Ecto.Migration

  def change do
    create table(:invite_codes) do
      add :code, :string, null: false
      add :max_uses, :integer, default: 1
      add :uses_count, :integer, default: 0
      add :expires_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :note, :text
      add :is_active, :boolean, default: true

      timestamps()
    end

    create unique_index(:invite_codes, [:code])
    create index(:invite_codes, [:is_active])
    create index(:invite_codes, [:expires_at])
  end
end
