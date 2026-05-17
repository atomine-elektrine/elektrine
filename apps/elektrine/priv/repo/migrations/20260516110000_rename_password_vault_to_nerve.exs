defmodule Elektrine.Repo.Migrations.RenamePasswordVaultToNerve do
  use Ecto.Migration

  def up do
    rename_if_exists(:password_vault_entries, :nerve_entries)
    rename_if_exists(:password_vault_settings, :nerve_settings)

    rename_sequence_if_exists(:password_vault_entries_id_seq, :nerve_entries_id_seq)
    rename_sequence_if_exists(:password_vault_settings_id_seq, :nerve_settings_id_seq)

    rename_constraint_if_exists(:nerve_entries, :password_vault_entries_pkey, :nerve_entries_pkey)

    rename_constraint_if_exists(
      :nerve_settings,
      :password_vault_settings_pkey,
      :nerve_settings_pkey
    )

    rename_index_if_exists(:password_vault_entries_user_id_index, :nerve_entries_user_id_index)

    rename_index_if_exists(
      :password_vault_entries_user_id_inserted_at_index,
      :nerve_entries_user_id_inserted_at_index
    )

    rename_index_if_exists(:password_vault_settings_user_id_index, :nerve_settings_user_id_index)

    rename_constraint_if_exists(
      :nerve_entries,
      :password_vault_entries_user_id_fkey,
      :nerve_entries_user_id_fkey
    )

    rename_constraint_if_exists(
      :nerve_settings,
      :password_vault_settings_user_id_fkey,
      :nerve_settings_user_id_fkey
    )
  end

  def down do
    rename_constraint_if_exists(
      :nerve_settings,
      :nerve_settings_pkey,
      :password_vault_settings_pkey
    )

    rename_constraint_if_exists(:nerve_entries, :nerve_entries_pkey, :password_vault_entries_pkey)

    rename_constraint_if_exists(
      :nerve_settings,
      :nerve_settings_user_id_fkey,
      :password_vault_settings_user_id_fkey
    )

    rename_constraint_if_exists(
      :nerve_entries,
      :nerve_entries_user_id_fkey,
      :password_vault_entries_user_id_fkey
    )

    rename_index_if_exists(:nerve_settings_user_id_index, :password_vault_settings_user_id_index)

    rename_index_if_exists(
      :nerve_entries_user_id_inserted_at_index,
      :password_vault_entries_user_id_inserted_at_index
    )

    rename_index_if_exists(:nerve_entries_user_id_index, :password_vault_entries_user_id_index)

    rename_if_exists(:nerve_settings, :password_vault_settings)
    rename_if_exists(:nerve_entries, :password_vault_entries)

    rename_sequence_if_exists(:nerve_settings_id_seq, :password_vault_settings_id_seq)
    rename_sequence_if_exists(:nerve_entries_id_seq, :password_vault_entries_id_seq)
  end

  defp rename_if_exists(from, to) do
    execute(
      "ALTER TABLE IF EXISTS #{from} RENAME TO #{to}",
      "ALTER TABLE IF EXISTS #{to} RENAME TO #{from}"
    )
  end

  defp rename_index_if_exists(from, to) do
    execute("ALTER INDEX IF EXISTS #{from} RENAME TO #{to}")
  end

  defp rename_sequence_if_exists(from, to) do
    execute("ALTER SEQUENCE IF EXISTS #{from} RENAME TO #{to}")
  end

  defp rename_constraint_if_exists(table, from, to) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = '#{from}'
          AND conrelid = to_regclass('#{table}')
      ) THEN
        ALTER TABLE #{table} RENAME CONSTRAINT #{from} TO #{to};
      END IF;
    END
    $$;
    """)
  end
end
