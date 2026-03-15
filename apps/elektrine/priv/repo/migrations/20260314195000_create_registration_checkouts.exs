defmodule Elektrine.Repo.Migrations.CreateRegistrationCheckouts do
  use Ecto.Migration

  def change do
    create table(:registration_checkouts) do
      add :stripe_checkout_session_id, :string, null: false
      add :lookup_token, :string, null: false
      add :product_slug, :string, null: false
      add :stripe_customer_id, :string
      add :stripe_payment_intent_id, :string
      add :customer_email, :string
      add :status, :string, null: false, default: "pending"
      add :fulfilled_at, :utc_datetime
      add :invite_code_id, references(:invite_codes, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:registration_checkouts, [:stripe_checkout_session_id])
    create unique_index(:registration_checkouts, [:lookup_token])
    create index(:registration_checkouts, [:product_slug])
    create index(:registration_checkouts, [:status])
  end
end
