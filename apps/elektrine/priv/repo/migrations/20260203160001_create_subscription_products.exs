defmodule Elektrine.Repo.Migrations.CreateSubscriptionProducts do
  use Ecto.Migration

  def change do
    create table(:subscription_products) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :features, {:array, :string}, default: []
      add :stripe_monthly_price_id, :string
      add :stripe_yearly_price_id, :string
      add :monthly_price_cents, :integer
      add :yearly_price_cents, :integer
      add :currency, :string, default: "usd"
      add :active, :boolean, default: true
      add :sort_order, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subscription_products, [:slug])
    create index(:subscription_products, [:active])

    # Update subscriptions table to reference products by slug instead of hardcoded string
    # Keep existing product column for backwards compatibility
  end
end
