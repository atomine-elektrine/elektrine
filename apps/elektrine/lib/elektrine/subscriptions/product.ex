defmodule Elektrine.Subscriptions.Product do
  @moduledoc """
  Schema for subscription products.

  Products are managed via admin panel and define what users can subscribe to.
  Each product has associated Stripe price IDs for monthly and yearly billing.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "subscription_products" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :features, {:array, :string}, default: []
    field :stripe_monthly_price_id, :string
    field :stripe_yearly_price_id, :string
    field :monthly_price_cents, :integer
    field :yearly_price_cents, :integer
    field :currency, :string, default: "usd"
    field :active, :boolean, default: true
    field :sort_order, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating/updating a product.
  """
  def changeset(product, attrs) do
    product
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :features,
      :stripe_monthly_price_id,
      :stripe_yearly_price_id,
      :monthly_price_cents,
      :yearly_price_cents,
      :currency,
      :active,
      :sort_order
    ])
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:slug, min: 1, max: 50)
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "only lowercase letters, numbers, and hyphens"
    )
    |> validate_number(:monthly_price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:yearly_price_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:slug)
  end

  @doc """
  Format price in cents as a display string.
  """
  def format_price(nil, _currency), do: nil

  def format_price(cents, currency) when is_integer(cents) do
    dollars = cents / 100
    symbol = currency_symbol(currency)
    "#{symbol}#{:erlang.float_to_binary(dollars, decimals: 2)}"
  end

  defp currency_symbol("usd"), do: "$"
  defp currency_symbol("eur"), do: "EUR "
  defp currency_symbol("gbp"), do: "GBP "
  defp currency_symbol(_), do: ""

  @doc """
  Check if product has monthly pricing configured.
  """
  def has_monthly?(%__MODULE__{stripe_monthly_price_id: id}) when is_binary(id) and id != "",
    do: true

  def has_monthly?(_), do: false

  @doc """
  Check if product has yearly pricing configured.
  """
  def has_yearly?(%__MODULE__{stripe_yearly_price_id: id}) when is_binary(id) and id != "",
    do: true

  def has_yearly?(_), do: false
end
