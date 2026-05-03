defmodule Atomine.CreditSpend do
  @moduledoc "One Atomine Credit spend against an action and audience."

  use Ecto.Schema
  import Ecto.Changeset

  alias Atomine.CreditAccount

  schema "atomine_credit_spends" do
    belongs_to :user, Elektrine.Accounts.User
    field :credit_type, :string
    field :amount, :integer
    field :action, :string
    field :audience, :string
    field :idempotency_key, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(spend, attrs) do
    spend
    |> cast(attrs, [
      :user_id,
      :credit_type,
      :amount,
      :action,
      :audience,
      :idempotency_key,
      :metadata
    ])
    |> validate_required([:user_id, :credit_type, :amount, :action, :audience])
    |> validate_inclusion(:credit_type, CreditAccount.credit_types())
    |> validate_number(:amount, greater_than: 0)
    |> validate_length(:action, min: 1, max: 120)
    |> validate_length(:audience, min: 1, max: 500)
    |> validate_length(:idempotency_key, max: 255)
    |> unique_constraint([:user_id, :credit_type, :action, :idempotency_key],
      name: :atomine_credit_spends_idempotency_index
    )
    |> foreign_key_constraint(:user_id)
  end
end
