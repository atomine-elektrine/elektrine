defmodule Elektrine.Accounts.TrustLevelLog do
  @moduledoc """
  Logs trust level changes for audit trail.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "trust_level_logs" do
    belongs_to :user, Elektrine.Accounts.User
    field :old_level, :integer
    field :new_level, :integer
    # "automatic", "manual", "penalty"
    field :reason, :string
    belongs_to :changed_by_user, Elektrine.Accounts.User
    field :notes, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:user_id, :old_level, :new_level, :reason, :changed_by_user_id, :notes])
    |> validate_required([:user_id, :old_level, :new_level, :reason])
    |> validate_inclusion(:reason, ["automatic", "manual", "penalty"])
    |> validate_number(:old_level, greater_than_or_equal_to: 0, less_than_or_equal_to: 4)
    |> validate_number(:new_level, greater_than_or_equal_to: 0, less_than_or_equal_to: 4)
  end
end
