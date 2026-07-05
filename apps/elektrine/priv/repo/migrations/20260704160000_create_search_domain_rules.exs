defmodule Elektrine.Repo.Migrations.CreateSearchDomainRules do
  use Ecto.Migration

  def change do
    create table(:search_domain_rules) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :domain, :string, null: false
      add :action, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:search_domain_rules, [:user_id, :domain])
  end
end
