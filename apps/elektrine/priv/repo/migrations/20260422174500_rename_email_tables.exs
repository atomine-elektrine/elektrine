defmodule Elektrine.Repo.Migrations.RenameEmailTables do
  use Ecto.Migration

  def up do
    rename table(:mailboxes), to: table(:email_mailboxes)
    rename table(:contacts), to: table(:email_contacts)

    execute("ALTER SEQUENCE IF EXISTS mailboxes_id_seq RENAME TO email_mailboxes_id_seq")
    execute("ALTER SEQUENCE IF EXISTS contacts_id_seq RENAME TO email_contacts_id_seq")

    rename index(:email_mailboxes, [:email], name: "mailboxes_email_index"),
      to: "email_mailboxes_email_index"

    rename index(:email_mailboxes, [:user_id], name: "mailboxes_user_id_index"),
      to: "email_mailboxes_user_id_index"

    rename index(:email_mailboxes, ["lower(email)"], name: "mailboxes_email_ci_unique"),
      to: "email_mailboxes_email_ci_unique"

    rename index(:email_contacts, [:user_id], name: "contacts_user_id_index"),
      to: "email_contacts_user_id_index"

    rename index(:email_contacts, [:user_id, :favorite], name: "contacts_user_id_favorite_index"),
      to: "email_contacts_user_id_favorite_index"

    rename index(:email_contacts, [:group_id], name: "contacts_group_id_index"),
      to: "email_contacts_group_id_index"

    rename index(:email_contacts, [:user_id, :email], name: "contacts_user_id_email_index"),
      to: "email_contacts_user_id_email_index"

    execute(
      "ALTER TABLE email_mailboxes RENAME CONSTRAINT mailboxes_user_id_fkey TO email_mailboxes_user_id_fkey",
      "ALTER TABLE email_mailboxes RENAME CONSTRAINT email_mailboxes_user_id_fkey TO mailboxes_user_id_fkey"
    )

    execute(
      "ALTER TABLE email_contacts RENAME CONSTRAINT contacts_user_id_fkey TO email_contacts_user_id_fkey",
      "ALTER TABLE email_contacts RENAME CONSTRAINT email_contacts_user_id_fkey TO contacts_user_id_fkey"
    )

    execute(
      "ALTER TABLE email_contacts RENAME CONSTRAINT contacts_group_id_fkey TO email_contacts_group_id_fkey",
      "ALTER TABLE email_contacts RENAME CONSTRAINT email_contacts_group_id_fkey TO contacts_group_id_fkey"
    )
  end

  def down do
    execute(
      "ALTER TABLE email_contacts RENAME CONSTRAINT email_contacts_group_id_fkey TO contacts_group_id_fkey",
      "ALTER TABLE email_contacts RENAME CONSTRAINT contacts_group_id_fkey TO email_contacts_group_id_fkey"
    )

    execute(
      "ALTER TABLE email_contacts RENAME CONSTRAINT email_contacts_user_id_fkey TO contacts_user_id_fkey",
      "ALTER TABLE email_contacts RENAME CONSTRAINT contacts_user_id_fkey TO email_contacts_user_id_fkey"
    )

    execute(
      "ALTER TABLE email_mailboxes RENAME CONSTRAINT email_mailboxes_user_id_fkey TO mailboxes_user_id_fkey",
      "ALTER TABLE email_mailboxes RENAME CONSTRAINT mailboxes_user_id_fkey TO email_mailboxes_user_id_fkey"
    )

    rename index(:email_contacts, [:user_id, :email], name: "email_contacts_user_id_email_index"),
      to: "contacts_user_id_email_index"

    rename index(:email_contacts, [:group_id], name: "email_contacts_group_id_index"),
      to: "contacts_group_id_index"

    rename index(:email_contacts, [:user_id, :favorite],
             name: "email_contacts_user_id_favorite_index"
           ),
           to: "contacts_user_id_favorite_index"

    rename index(:email_contacts, [:user_id], name: "email_contacts_user_id_index"),
      to: "contacts_user_id_index"

    rename index(:email_mailboxes, ["lower(email)"], name: "email_mailboxes_email_ci_unique"),
      to: "mailboxes_email_ci_unique"

    rename index(:email_mailboxes, [:user_id], name: "email_mailboxes_user_id_index"),
      to: "mailboxes_user_id_index"

    rename index(:email_mailboxes, [:email], name: "email_mailboxes_email_index"),
      to: "mailboxes_email_index"

    execute("ALTER SEQUENCE IF EXISTS email_contacts_id_seq RENAME TO contacts_id_seq")
    execute("ALTER SEQUENCE IF EXISTS email_mailboxes_id_seq RENAME TO mailboxes_id_seq")

    rename table(:email_contacts), to: table(:contacts)
    rename table(:email_mailboxes), to: table(:mailboxes)
  end
end
