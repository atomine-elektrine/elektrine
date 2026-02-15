defmodule Elektrine.Repo.Migrations.CreateEmailUnsubscribes do
  use Ecto.Migration

  def change do
    create table(:email_unsubscribes) do
      add :email, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :list_id, :string
      add :token, :string, null: false
      add :unsubscribed_at, :utc_datetime, null: false
      add :ip_address, :string
      add :user_agent, :text

      timestamps()
    end

    create index(:email_unsubscribes, [:email])
    create index(:email_unsubscribes, [:user_id])
    create index(:email_unsubscribes, [:token])
    create unique_index(:email_unsubscribes, [:email, :list_id])
  end
end
