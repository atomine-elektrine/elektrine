defmodule Elektrine.Repo.Migrations.AddSocialIdentityToUsers do
  use Ecto.Migration

  def change do
    # Add social identity fields to users
    alter table(:users) do
      add_if_not_exists :handle, :string
      add_if_not_exists :display_name, :string
      add_if_not_exists :unique_id, :string
      add_if_not_exists :handle_changed_at, :utc_datetime
    end

    # Create handle history table for 90-day reservation
    create table(:handle_history) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :handle, :string, null: false
      add :used_from, :utc_datetime, null: false
      add :used_until, :utc_datetime
      # 90 days after change
      add :reserved_until, :utc_datetime

      timestamps()
    end

    # Create indexes (but not unique yet - will add after grandfather migration)
    create index(:users, [:handle])
    create index(:users, [:unique_id])
    create index(:handle_history, [:handle])
    create index(:handle_history, [:user_id])
    create index(:handle_history, [:reserved_until])

    # Flush before next operations
    flush()

    # Generate unique_id for existing users
    execute """
            UPDATE users
            SET unique_id = 'usr_' || substr(md5(random()::text || id::text), 1, 8)
            WHERE unique_id IS NULL
            """,
            ""

    # Set display_name to username for existing users (they can change later)
    execute """
            UPDATE users
            SET display_name = username
            WHERE display_name IS NULL
            """,
            ""
  end

  def down do
    alter table(:users) do
      remove :handle
      remove :display_name
      remove :unique_id
      remove :handle_changed_at
    end

    drop table(:handle_history)
  end
end
