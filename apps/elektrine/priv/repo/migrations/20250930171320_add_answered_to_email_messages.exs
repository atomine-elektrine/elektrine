defmodule Elektrine.Repo.Migrations.AddAnsweredToEmailMessages do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      add :answered, :boolean, default: false, null: false
    end

    create index(:email_messages, [:answered])
  end
end
