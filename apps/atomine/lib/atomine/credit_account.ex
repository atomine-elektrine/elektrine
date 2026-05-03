defmodule Atomine.CreditAccount do
  @moduledoc "Per-user balance for one Atomine Credit type."

  use Ecto.Schema
  import Ecto.Changeset

  @credit_types ~w(atomine_credit dm_credit email_credit link_credit signup_credit api_credit invite_credit)

  schema "atomine_credit_accounts" do
    belongs_to :user, Elektrine.Accounts.User
    field :credit_type, :string
    field :balance, :integer, default: 0
    field :lifetime_earned, :integer, default: 0
    field :lifetime_spent, :integer, default: 0
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def credit_types, do: @credit_types

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :user_id,
      :credit_type,
      :balance,
      :lifetime_earned,
      :lifetime_spent,
      :metadata
    ])
    |> validate_required([:user_id, :credit_type, :balance, :lifetime_earned, :lifetime_spent])
    |> validate_inclusion(:credit_type, @credit_types)
    |> validate_number(:balance, greater_than_or_equal_to: 0)
    |> validate_number(:lifetime_earned, greater_than_or_equal_to: 0)
    |> validate_number(:lifetime_spent, greater_than_or_equal_to: 0)
    |> unique_constraint([:user_id, :credit_type])
    |> foreign_key_constraint(:user_id)
  end
end
