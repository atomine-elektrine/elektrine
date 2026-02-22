defmodule Elektrine.Accounts.InviteCode do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "invite_codes" do
    field :code, :string
    field :max_uses, :integer, default: 1
    field :uses_count, :integer, default: 0
    field :expires_at, :utc_datetime
    field :note, :string
    field :is_active, :boolean, default: true

    belongs_to :created_by, Elektrine.Accounts.User
    has_many :uses, Elektrine.Accounts.InviteCodeUse

    timestamps()
  end

  @doc false
  def changeset(invite_code, attrs) do
    invite_code
    |> cast(attrs, [:code, :max_uses, :expires_at, :note, :is_active, :created_by_id])
    |> validate_required([:code])
    |> validate_number(:max_uses, greater_than: 0)
    |> unique_constraint(:code)
    |> validate_code_format()
  end

  defp validate_code_format(changeset) do
    validate_change(changeset, :code, fn :code, code ->
      if String.match?(code, ~r/^[A-Z0-9]{6,}$/i) do
        []
      else
        [code: "must be at least 6 characters long and contain only letters and numbers"]
      end
    end)
  end

  def generate_code do
    :crypto.strong_rand_bytes(4)
    |> Base.encode32()
    |> String.replace(~r/[=]+$/, "")
    |> String.upcase()
  end

  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end

  def exhausted?(%__MODULE__{uses_count: uses_count, max_uses: max_uses}) do
    uses_count >= max_uses
  end

  def valid_for_use?(%__MODULE__{} = invite_code) do
    invite_code.is_active && !expired?(invite_code) && !exhausted?(invite_code)
  end
end
