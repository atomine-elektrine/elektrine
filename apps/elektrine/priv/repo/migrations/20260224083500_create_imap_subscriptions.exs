defmodule Elektrine.Repo.Migrations.CreateImapSubscriptions do
  use Ecto.Migration

  def change do
    create table(:imap_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :folder_name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:imap_subscriptions, [:user_id])
    create unique_index(:imap_subscriptions, [:user_id, :folder_name])
  end
end
