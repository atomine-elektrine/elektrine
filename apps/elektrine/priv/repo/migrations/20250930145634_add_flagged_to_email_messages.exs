defmodule Elektrine.Repo.Migrations.AddFlaggedToEmailMessages do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      add :flagged, :boolean, default: false, null: false
    end
  end
end
