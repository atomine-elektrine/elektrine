defmodule Elektrine.Repo.Migrations.CreateBillingSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :product, :string, null: false
      add :stripe_customer_id, :string
      add :stripe_subscription_id, :string
      add :stripe_price_id, :string
      add :status, :string, null: false, default: "incomplete"
      add :current_period_start, :utc_datetime
      add :current_period_end, :utc_datetime
      add :canceled_at, :utc_datetime
      add :cancel_at_period_end, :boolean, default: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    # One subscription per user per product
    create unique_index(:subscriptions, [:user_id, :product])

    create unique_index(:subscriptions, [:stripe_subscription_id],
             where: "stripe_subscription_id IS NOT NULL"
           )

    create index(:subscriptions, [:stripe_customer_id])
    create index(:subscriptions, [:status])
    create index(:subscriptions, [:product])
  end
end
