defmodule Elektrine.Repo.Migrations.AddPreferredEmailDomainToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :preferred_email_domain, :string, default: "z.org"
    end
  end
end
