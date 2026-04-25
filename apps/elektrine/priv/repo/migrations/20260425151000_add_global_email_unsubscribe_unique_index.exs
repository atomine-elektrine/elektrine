defmodule Elektrine.Repo.Migrations.AddGlobalEmailUnsubscribeUniqueIndex do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM email_unsubscribes a
    USING email_unsubscribes b
    WHERE a.list_id IS NULL
      AND b.list_id IS NULL
      AND a.email = b.email
      AND a.id < b.id
    """)

    create unique_index(:email_unsubscribes, [:email],
             where: "list_id IS NULL",
             name: :email_unsubscribes_email_global_unique_index
           )
  end

  def down do
    drop_if_exists index(:email_unsubscribes, [:email],
                     name: :email_unsubscribes_email_global_unique_index
                   )
  end
end
