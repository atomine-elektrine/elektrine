defmodule Elektrine.Repo.Migrations.CreateInviteCodeUses do
  use Ecto.Migration

  def change do
    create table(:invite_code_uses) do
      add :invite_code_id, references(:invite_codes, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :used_at, :utc_datetime, default: fragment("NOW()"), null: false
    end

    create index(:invite_code_uses, [:invite_code_id])
    create index(:invite_code_uses, [:user_id])
    create unique_index(:invite_code_uses, [:user_id], name: :invite_code_uses_user_id_unique)
  end
end
