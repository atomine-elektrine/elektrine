defmodule Elektrine.Repo.Migrations.AddStripeCustomerIdToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :stripe_customer_id, :string
    end

    execute("""
    UPDATE users
    SET stripe_customer_id = source.stripe_customer_id
    FROM (
      SELECT user_id, MAX(stripe_customer_id) AS stripe_customer_id
      FROM subscriptions
      WHERE stripe_customer_id IS NOT NULL
      GROUP BY user_id
      HAVING COUNT(DISTINCT stripe_customer_id) = 1
    ) AS source
    WHERE users.id = source.user_id
    """)

    create unique_index(:users, [:stripe_customer_id], where: "stripe_customer_id IS NOT NULL")
  end

  def down do
    drop_if_exists unique_index(:users, [:stripe_customer_id],
                     where: "stripe_customer_id IS NOT NULL"
                   )

    alter table(:users) do
      remove :stripe_customer_id
    end
  end
end
