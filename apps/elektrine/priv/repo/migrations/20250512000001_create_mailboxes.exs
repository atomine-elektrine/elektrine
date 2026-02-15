defmodule Elektrine.Repo.Migrations.CreateMailboxes do
  use Ecto.Migration

  def change do
    create table(:mailboxes) do
      add :email, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:mailboxes, [:email])
    # Each user has exactly one mailbox
    create unique_index(:mailboxes, [:user_id])
  end
end
