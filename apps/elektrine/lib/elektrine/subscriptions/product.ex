defmodule Elektrine.Subscriptions.Product do
  @moduledoc """
  Schema for subscription products.

  Products are managed via admin panel and define what users can subscribe to.
  Products can be billed as recurring subscriptions or one-time purchases.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @billing_types ~w(recurring one_time)

  schema "subscription_products" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :features, {:array, :string}, default: []
    field :billing_type, :string, default: "recurring"
    field :stripe_monthly_price_id, :string
    field :stripe_yearly_price_id, :string
    field :stripe_one_time_price_id, :string
    field :monthly_price_cents, :integer
    field :yearly_price_cents, :integer
    field :one_time_price_cents, :integer
    field :currency, :string, default: "usd"
    field :active, :boolean, default: true
    field :sort_order, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a product.
  """
  def create_changeset(product, attrs) do
    product
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :features,
      :billing_type,
      :stripe_monthly_price_id,
      :stripe_yearly_price_id,
      :stripe_one_time_price_id,
      :monthly_price_cents,
      :yearly_price_cents,
      :one_time_price_cents,
      :currency,
      :active,
      :sort_order
    ])
    |> normalize_string_fields()
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:slug, min: 1, max: 50)
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "only lowercase letters, numbers, and hyphens"
    )
    |> validate_inclusion(:billing_type, @billing_types)
    |> validate_number(:monthly_price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:yearly_price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:one_time_price_cents, greater_than_or_equal_to: 0)
    |> validate_billing_type_pricing()
    |> unique_constraint(:slug)
  end

  @doc """
  Changeset for updating an existing product.
  """
  def update_changeset(product, attrs) do
    product
    |> cast(attrs, [
      :name,
      :description,
      :features,
      :billing_type,
      :stripe_monthly_price_id,
      :stripe_yearly_price_id,
      :stripe_one_time_price_id,
      :monthly_price_cents,
      :yearly_price_cents,
      :one_time_price_cents,
      :currency,
      :active,
      :sort_order
    ])
    |> normalize_string_fields()
    |> reject_slug_change(attrs)
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:slug, min: 1, max: 50)
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "only lowercase letters, numbers, and hyphens"
    )
    |> validate_inclusion(:billing_type, @billing_types)
    |> validate_number(:monthly_price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:yearly_price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:one_time_price_cents, greater_than_or_equal_to: 0)
    |> validate_billing_type_pricing()
    |> unique_constraint(:slug)
  end

  defp normalize_string_fields(changeset) do
    changeset
    |> update_change(:name, &normalize_optional_string/1)
    |> update_change(:slug, &normalize_optional_string/1)
    |> update_change(:description, &normalize_optional_string/1)
    |> update_change(:billing_type, &normalize_optional_string/1)
    |> update_change(:stripe_monthly_price_id, &normalize_optional_string/1)
    |> update_change(:stripe_yearly_price_id, &normalize_optional_string/1)
    |> update_change(:stripe_one_time_price_id, &normalize_optional_string/1)
    |> update_change(:currency, &normalize_optional_string/1)
  end

  defp validate_billing_type_pricing(changeset) do
    case get_field(changeset, :billing_type) do
      "one_time" ->
        if recurring_pricing_present?(changeset) do
          add_error(
            changeset,
            :billing_type,
            "one-time products cannot include monthly or yearly pricing"
          )
        else
          changeset
        end

      _ ->
        if one_time_pricing_present?(changeset) do
          add_error(
            changeset,
            :billing_type,
            "recurring products cannot include one-time pricing"
          )
        else
          changeset
        end
    end
  end

  defp recurring_pricing_present?(changeset) do
    present?(get_field(changeset, :stripe_monthly_price_id)) or
      present?(get_field(changeset, :stripe_yearly_price_id)) or
      not is_nil(get_field(changeset, :monthly_price_cents)) or
      not is_nil(get_field(changeset, :yearly_price_cents))
  end

  defp one_time_pricing_present?(changeset) do
    present?(get_field(changeset, :stripe_one_time_price_id)) or
      not is_nil(get_field(changeset, :one_time_price_cents))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp reject_slug_change(changeset, attrs) do
    case attr_value(attrs, :slug) do
      nil ->
        changeset

      slug when slug == changeset.data.slug ->
        changeset

      _ ->
        add_error(changeset, :slug, "cannot be changed after creation")
    end
  end

  defp attr_value(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value), do: value

  @doc """
  Format price in cents as a display string.
  """
  def format_price(nil, _currency), do: nil

  def format_price(cents, currency) when is_integer(cents) do
    dollars = cents / 100
    symbol = currency_symbol(currency)
    "#{symbol}#{:erlang.float_to_binary(dollars, decimals: 2)}"
  end

  def billing_types, do: @billing_types

  def recurring?(%__MODULE__{billing_type: "one_time"}), do: false
  def recurring?(%__MODULE__{}), do: true
  def recurring?(_), do: false

  def one_time?(%__MODULE__{billing_type: "one_time"}), do: true
  def one_time?(_), do: false

  defp currency_symbol("usd"), do: "$"
  defp currency_symbol("eur"), do: "EUR "
  defp currency_symbol("gbp"), do: "GBP "
  defp currency_symbol(_), do: ""

  @doc """
  Check if product has monthly pricing configured.
  """
  def has_monthly?(%__MODULE__{billing_type: "recurring", stripe_monthly_price_id: id})
      when is_binary(id) and id != "",
      do: true

  def has_monthly?(_), do: false

  @doc """
  Check if product has yearly pricing configured.
  """
  def has_yearly?(%__MODULE__{billing_type: "recurring", stripe_yearly_price_id: id})
      when is_binary(id) and id != "",
      do: true

  def has_yearly?(_), do: false

  @doc """
  Check if product has one-time pricing configured.
  """
  def has_one_time?(%__MODULE__{billing_type: "one_time", stripe_one_time_price_id: id})
      when is_binary(id) and id != "",
      do: true

  def has_one_time?(_), do: false
end
