defmodule Elektrine.Repo.Migrations.CreateEmailCategoryPreferences do
  use Ecto.Migration

  def change do
    create table(:email_category_preferences) do
      add :email, :string
      add :domain, :string
      add :category, :string, null: false
      add :confidence, :float, null: false, default: 0.7
      add :learned_count, :integer, null: false, default: 1
      add :source, :string, null: false, default: "manual_move"
      add :last_learned_at, :utc_datetime
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:email_category_preferences, [:user_id])
    create index(:email_category_preferences, [:email])
    create index(:email_category_preferences, [:domain])

    create unique_index(:email_category_preferences, [:user_id, :email],
             where: "email IS NOT NULL",
             name: :email_category_preferences_user_email_idx
           )

    create unique_index(:email_category_preferences, [:user_id, :domain],
             where: "domain IS NOT NULL",
             name: :email_category_preferences_user_domain_idx
           )

    create constraint(
             :email_category_preferences,
             :email_category_preferences_email_or_domain_check,
             check:
               "(email IS NOT NULL AND domain IS NULL) OR (email IS NULL AND domain IS NOT NULL)"
           )

    create constraint(
             :email_category_preferences,
             :email_category_preferences_category_check,
             check: "category IN ('feed', 'ledger')"
           )
  end
end
