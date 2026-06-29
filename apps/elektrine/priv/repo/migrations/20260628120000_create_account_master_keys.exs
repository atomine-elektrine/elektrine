defmodule Elektrine.Repo.Migrations.CreateAccountMasterKeys do
  use Ecto.Migration

  def change do
    create table(:account_master_keys) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # The user's Master Data Key, wrapped under a passphrase-derived KEK and,
      # separately, under a recovery-code-derived KEK. The server only ever sees
      # these wrapped blobs (zero-knowledge); it never holds the passphrase or MDK.
      add :wrapped_dek, :map, null: false
      add :wrapped_dek_recovery, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:account_master_keys, [:user_id])
  end
end
