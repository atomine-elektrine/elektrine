defmodule Elektrine.Subscriptions.Subscription do
  @moduledoc """
  Schema for user subscriptions.

  This is a universal subscription system that can be used for any product.
  Each subscription tracks a user's access to a specific product.
  Products are managed via admin panel in the subscription_products table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(
    incomplete
    incomplete_expired
    trialing
    active
    past_due
    canceled
    unpaid
    paused
  )

  schema "subscriptions" do
    field :product, :string
    field :stripe_customer_id, :string
    field :stripe_subscription_id, :string
    field :stripe_price_id, :string
    field :status, :string, default: "incomplete"
    field :current_period_start, :utc_datetime
    field :current_period_end, :utc_datetime
    field :canceled_at, :utc_datetime
    field :cancel_at_period_end, :boolean, default: false
    field :metadata, :map, default: %{}

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns list of valid subscription statuses.
  """
  def statuses, do: @statuses

  @doc """
  Returns statuses that grant access to the product.
  """
  def active_statuses, do: ~w(active trialing)

  @doc """
  Changeset for creating a new subscription.
  """
  def create_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :user_id,
      :product,
      :stripe_customer_id,
      :stripe_subscription_id,
      :stripe_price_id,
      :status,
      :current_period_start,
      :current_period_end,
      :canceled_at,
      :cancel_at_period_end,
      :metadata
    ])
    |> validate_required([:user_id, :product])
    |> validate_length(:product, min: 1, max: 50)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:user_id, :product])
    |> unique_constraint(:stripe_subscription_id)
  end

  @doc """
  Changeset for updating subscription from Stripe webhook.
  """
  def webhook_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :stripe_subscription_id,
      :stripe_price_id,
      :status,
      :current_period_start,
      :current_period_end,
      :canceled_at,
      :cancel_at_period_end,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Changeset for setting Stripe customer ID.
  """
  def customer_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:stripe_customer_id])
    |> validate_required([:stripe_customer_id])
  end

  @doc """
  Check if subscription grants access to the product.
  """
  def has_access?(%__MODULE__{status: status}) do
    status in active_statuses()
  end

  def has_access?(_), do: false
end
