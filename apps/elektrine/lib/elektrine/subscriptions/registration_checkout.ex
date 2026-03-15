defmodule Elektrine.Subscriptions.RegistrationCheckout do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending fulfilled)

  schema "registration_checkouts" do
    field :stripe_checkout_session_id, :string
    field :lookup_token, :string
    field :product_slug, :string
    field :stripe_customer_id, :string
    field :stripe_payment_intent_id, :string
    field :customer_email, :string
    field :status, :string, default: "pending"
    field :fulfilled_at, :utc_datetime

    belongs_to :invite_code, Elektrine.Accounts.InviteCode

    timestamps(type: :utc_datetime)
  end

  def create_changeset(checkout, attrs) do
    checkout
    |> cast(attrs, [
      :stripe_checkout_session_id,
      :lookup_token,
      :product_slug,
      :stripe_customer_id,
      :stripe_payment_intent_id,
      :customer_email,
      :status,
      :fulfilled_at,
      :invite_code_id
    ])
    |> validate_required([:stripe_checkout_session_id, :lookup_token, :product_slug, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:stripe_checkout_session_id)
    |> unique_constraint(:lookup_token)
  end

  def fulfill_changeset(checkout, attrs) do
    checkout
    |> cast(attrs, [
      :stripe_customer_id,
      :stripe_payment_intent_id,
      :customer_email,
      :status,
      :fulfilled_at,
      :invite_code_id
    ])
    |> validate_required([:status, :invite_code_id])
    |> validate_inclusion(:status, @statuses)
  end
end
