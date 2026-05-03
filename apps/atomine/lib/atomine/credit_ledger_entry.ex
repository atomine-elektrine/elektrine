defmodule Atomine.CreditLedgerEntry do
  @moduledoc "Immutable Atomine Credit accounting event."

  use Ecto.Schema
  import Ecto.Changeset

  alias Atomine.CreditAccount

  schema "atomine_credit_ledger_entries" do
    belongs_to :user, Elektrine.Accounts.User
    field :credit_type, :string
    field :amount, :integer
    field :reason, :string
    field :action, :string
    field :reference_type, :string
    field :reference_id, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :user_id,
      :credit_type,
      :amount,
      :reason,
      :action,
      :reference_type,
      :reference_id,
      :metadata
    ])
    |> validate_required([:user_id, :credit_type, :amount, :reason])
    |> validate_inclusion(:credit_type, CreditAccount.credit_types())
    |> validate_length(:reason, min: 1, max: 120)
    |> validate_length(:action, max: 120)
    |> validate_length(:reference_type, max: 120)
    |> validate_length(:reference_id, max: 255)
    |> validate_change(:amount, fn :amount, amount ->
      if amount == 0, do: [amount: "must not be zero"], else: []
    end)
    |> foreign_key_constraint(:user_id)
  end
end
