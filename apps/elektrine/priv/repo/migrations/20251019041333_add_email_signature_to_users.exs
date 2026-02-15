defmodule Elektrine.Repo.Migrations.AddEmailSignatureToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email_signature, :text
    end
  end
end
