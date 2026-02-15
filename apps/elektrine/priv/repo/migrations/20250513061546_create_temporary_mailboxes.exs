defmodule Elektrine.Repo.Migrations.CreateTemporaryMailboxes do
  use Ecto.Migration

  def change do
    create table(:temporary_mailboxes) do
      add :email, :string, null: false
      add :token, :string, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:temporary_mailboxes, [:email])
    create unique_index(:temporary_mailboxes, [:token])
    create index(:temporary_mailboxes, [:expires_at])
  end
end
