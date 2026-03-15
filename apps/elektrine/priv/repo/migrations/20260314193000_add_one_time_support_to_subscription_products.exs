defmodule Elektrine.Repo.Migrations.AddOneTimeSupportToSubscriptionProducts do
  use Ecto.Migration

  def change do
    alter table(:subscription_products) do
      add :billing_type, :string, null: false, default: "recurring"
      add :stripe_one_time_price_id, :string
      add :one_time_price_cents, :integer
    end

    create index(:subscription_products, [:billing_type])
  end
end
