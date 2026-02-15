defmodule Elektrine.Repo.Migrations.AddSpamAndArchivedToEmailMessages do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      add :spam, :boolean, default: false
      add :archived, :boolean, default: false
    end

    create index(:email_messages, [:spam])
    create index(:email_messages, [:archived])
  end
end
