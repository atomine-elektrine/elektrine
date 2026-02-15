defmodule Elektrine.Repo.Migrations.AddHiddenMessages do
  use Ecto.Migration

  def change do
    # Table to track which messages are hidden for specific users
    create table(:user_hidden_messages) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :hidden_at, :utc_datetime, default: fragment("now()")

      timestamps()
    end

    create unique_index(:user_hidden_messages, [:user_id, :message_id])
    create index(:user_hidden_messages, [:user_id])
    create index(:user_hidden_messages, [:message_id])
  end
end
