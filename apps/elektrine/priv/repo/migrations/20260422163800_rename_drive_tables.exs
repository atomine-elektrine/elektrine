defmodule Elektrine.Repo.Migrations.RenameDriveTables do
  use Ecto.Migration

  def up do
    rename table(:stored_files), to: table(:drive_files)
    rename table(:stored_folders), to: table(:drive_folders)
    rename table(:file_shares), to: table(:drive_shares)

    rename table(:drive_shares), :stored_file_id, to: :drive_file_id

    rename index(:drive_files, [:user_id, :path], name: "stored_files_user_id_path_index"),
      to: "drive_files_user_id_path_index"

    rename index(:drive_files, [:user_id], name: "stored_files_user_id_index"),
      to: "drive_files_user_id_index"

    rename index(:drive_folders, [:user_id, :path], name: "stored_folders_user_id_path_index"),
      to: "drive_folders_user_id_path_index"

    rename index(:drive_folders, [:user_id], name: "stored_folders_user_id_index"),
      to: "drive_folders_user_id_index"

    rename index(:drive_shares, [:token], name: "file_shares_token_index"),
      to: "drive_shares_token_index"

    rename index(:drive_shares, [:stored_file_id], name: "file_shares_stored_file_id_index"),
      to: "drive_shares_drive_file_id_index"

    rename index(:drive_shares, [:user_id], name: "file_shares_user_id_index"),
      to: "drive_shares_user_id_index"

    rename index(:drive_shares, [:expires_at], name: "file_shares_expires_at_index"),
      to: "drive_shares_expires_at_index"

    rename index(:drive_shares, [:access_level], name: "file_shares_access_level_index"),
      to: "drive_shares_access_level_index"

    execute(
      "ALTER TABLE drive_shares RENAME CONSTRAINT file_shares_stored_file_id_fkey TO drive_shares_drive_file_id_fkey",
      "ALTER TABLE drive_shares RENAME CONSTRAINT drive_shares_drive_file_id_fkey TO file_shares_stored_file_id_fkey"
    )

    execute(
      "ALTER TABLE drive_shares RENAME CONSTRAINT file_shares_user_id_fkey TO drive_shares_user_id_fkey",
      "ALTER TABLE drive_shares RENAME CONSTRAINT drive_shares_user_id_fkey TO file_shares_user_id_fkey"
    )

    execute(
      "ALTER TABLE drive_files RENAME CONSTRAINT stored_files_user_id_fkey TO drive_files_user_id_fkey",
      "ALTER TABLE drive_files RENAME CONSTRAINT drive_files_user_id_fkey TO stored_files_user_id_fkey"
    )

    execute(
      "ALTER TABLE drive_folders RENAME CONSTRAINT stored_folders_user_id_fkey TO drive_folders_user_id_fkey",
      "ALTER TABLE drive_folders RENAME CONSTRAINT drive_folders_user_id_fkey TO stored_folders_user_id_fkey"
    )

    execute("ALTER SEQUENCE IF EXISTS stored_files_id_seq RENAME TO drive_files_id_seq")
    execute("ALTER SEQUENCE IF EXISTS stored_folders_id_seq RENAME TO drive_folders_id_seq")
    execute("ALTER SEQUENCE IF EXISTS file_shares_id_seq RENAME TO drive_shares_id_seq")
  end

  def down do
    execute("ALTER SEQUENCE IF EXISTS drive_files_id_seq RENAME TO stored_files_id_seq")
    execute("ALTER SEQUENCE IF EXISTS drive_folders_id_seq RENAME TO stored_folders_id_seq")
    execute("ALTER SEQUENCE IF EXISTS drive_shares_id_seq RENAME TO file_shares_id_seq")

    execute(
      "ALTER TABLE drive_folders RENAME CONSTRAINT drive_folders_user_id_fkey TO stored_folders_user_id_fkey",
      "ALTER TABLE drive_folders RENAME CONSTRAINT stored_folders_user_id_fkey TO drive_folders_user_id_fkey"
    )

    execute(
      "ALTER TABLE drive_files RENAME CONSTRAINT drive_files_user_id_fkey TO stored_files_user_id_fkey",
      "ALTER TABLE drive_files RENAME CONSTRAINT stored_files_user_id_fkey TO drive_files_user_id_fkey"
    )

    execute(
      "ALTER TABLE drive_shares RENAME CONSTRAINT drive_shares_user_id_fkey TO file_shares_user_id_fkey",
      "ALTER TABLE drive_shares RENAME CONSTRAINT file_shares_user_id_fkey TO drive_shares_user_id_fkey"
    )

    execute(
      "ALTER TABLE drive_shares RENAME CONSTRAINT drive_shares_drive_file_id_fkey TO file_shares_stored_file_id_fkey",
      "ALTER TABLE drive_shares RENAME CONSTRAINT file_shares_stored_file_id_fkey TO drive_shares_drive_file_id_fkey"
    )

    rename index(:drive_shares, [:access_level], name: "drive_shares_access_level_index"),
      to: "file_shares_access_level_index"

    rename index(:drive_shares, [:expires_at], name: "drive_shares_expires_at_index"),
      to: "file_shares_expires_at_index"

    rename index(:drive_shares, [:user_id], name: "drive_shares_user_id_index"),
      to: "file_shares_user_id_index"

    rename index(:drive_shares, [:drive_file_id], name: "drive_shares_drive_file_id_index"),
      to: "file_shares_stored_file_id_index"

    rename index(:drive_shares, [:token], name: "drive_shares_token_index"),
      to: "file_shares_token_index"

    rename index(:drive_folders, [:user_id], name: "drive_folders_user_id_index"),
      to: "stored_folders_user_id_index"

    rename index(:drive_folders, [:user_id, :path], name: "drive_folders_user_id_path_index"),
      to: "stored_folders_user_id_path_index"

    rename index(:drive_files, [:user_id], name: "drive_files_user_id_index"),
      to: "stored_files_user_id_index"

    rename index(:drive_files, [:user_id, :path], name: "drive_files_user_id_path_index"),
      to: "stored_files_user_id_path_index"

    rename table(:drive_shares), :drive_file_id, to: :stored_file_id

    rename table(:drive_shares), to: table(:file_shares)
    rename table(:drive_folders), to: table(:stored_folders)
    rename table(:drive_files), to: table(:stored_files)
  end
end
