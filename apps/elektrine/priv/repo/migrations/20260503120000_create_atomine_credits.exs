defmodule Elektrine.Repo.Migrations.CreateAtomineCredits do
  use Ecto.Migration

  def change do
    create table(:atomine_credit_accounts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :credit_type, :string, null: false
      add :balance, :integer, null: false, default: 0
      add :lifetime_earned, :integer, null: false, default: 0
      add :lifetime_spent, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:atomine_credit_accounts, [:user_id, :credit_type])
    create index(:atomine_credit_accounts, [:credit_type])

    create table(:atomine_credit_ledger_entries) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :credit_type, :string, null: false
      add :amount, :integer, null: false
      add :reason, :string, null: false
      add :action, :string
      add :reference_type, :string
      add :reference_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:atomine_credit_ledger_entries, [:user_id, :credit_type])
    create index(:atomine_credit_ledger_entries, [:reason])
    create index(:atomine_credit_ledger_entries, [:action])

    create unique_index(
             :atomine_credit_ledger_entries,
             [:user_id, :credit_type, :reason, :reference_type, :reference_id],
             name: :atomine_credit_ledger_entries_grant_once_index,
             where: "amount > 0 AND reference_type IS NOT NULL AND reference_id IS NOT NULL"
           )

    create table(:atomine_credit_spends) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :credit_type, :string, null: false
      add :amount, :integer, null: false
      add :action, :string, null: false
      add :audience, :string, null: false
      add :idempotency_key, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:atomine_credit_spends, [:user_id, :credit_type])
    create index(:atomine_credit_spends, [:action])
    create index(:atomine_credit_spends, [:audience])

    create unique_index(
             :atomine_credit_spends,
             [:user_id, :credit_type, :action, :idempotency_key],
             name: :atomine_credit_spends_idempotency_index,
             where: "idempotency_key IS NOT NULL"
           )
  end
end
