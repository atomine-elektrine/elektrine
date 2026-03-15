defmodule Elektrine.Accounts.InviteCode do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @code_regex ~r/^[A-Z0-9]{6,}$/

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
    if invite_code.id do
      update_changeset(invite_code, attrs)
    else
      create_changeset(invite_code, attrs)
    end
  end

  @doc false
  def create_changeset(invite_code, attrs) do
    invite_code
    |> cast(attrs, [:code, :max_uses, :expires_at, :note, :is_active, :created_by_id])
    |> normalize_code_field()
    |> validate_required([:code])
    |> validate_number(:max_uses, greater_than: 0)
    |> unique_constraint(:code)
    |> unique_constraint(:code, name: :invite_codes_code_upper_unique)
    |> validate_code_format()
  end

  @doc false
  def update_changeset(invite_code, attrs) do
    invite_code
    |> cast(attrs, [:max_uses, :expires_at, :note, :is_active])
    |> validate_number(:max_uses, greater_than: 0)
    |> validate_max_uses_not_below_current_usage()
    |> validate_code_format()
  end

  defp validate_code_format(changeset) do
    validate_change(changeset, :code, fn :code, code ->
      if String.match?(code, @code_regex) do
        []
      else
        [code: "must be at least 6 characters long and contain only letters and numbers"]
      end
    end)
  end

  defp validate_max_uses_not_below_current_usage(%Ecto.Changeset{} = changeset) do
    max_uses = get_field(changeset, :max_uses)
    current_uses = changeset.data.uses_count || 0

    if is_integer(max_uses) and max_uses < current_uses do
      add_error(changeset, :max_uses, "cannot be less than current uses (#{current_uses})")
    else
      changeset
    end
  end

  defp normalize_code_field(changeset) do
    update_change(changeset, :code, &normalize_code/1)
  end

  def normalize_code(code) when is_binary(code) do
    code
    |> String.trim()
    |> String.upcase()
  end

  def normalize_code(_), do: nil

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
