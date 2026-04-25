defmodule Elektrine.Repo.Migrations.AddEmailMailboxesUsernameCiUnique do
  use Ecto.Migration

  def change do
    create unique_index(:email_mailboxes, ["lower(username)"],
             name: :email_mailboxes_username_ci_unique,
             where: "username IS NOT NULL"
           )
  end
end
