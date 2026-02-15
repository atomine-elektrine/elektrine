defmodule Elektrine.Accounts.UserBlock do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_blocks" do
    belongs_to :blocker, Elektrine.Accounts.User
    belongs_to :blocked, Elektrine.Accounts.User
    field :reason, :string

    timestamps()
  end

  @doc false
  def changeset(user_block, attrs) do
    user_block
    |> cast(attrs, [:blocker_id, :blocked_id, :reason])
    |> validate_required([:blocker_id, :blocked_id])
    |> validate_length(:reason, max: 255)
    |> validate_not_self_block()
    |> unique_constraint([:blocker_id, :blocked_id])
    |> foreign_key_constraint(:blocker_id)
    |> foreign_key_constraint(:blocked_id)
  end

  defp validate_not_self_block(changeset) do
    blocker_id = get_field(changeset, :blocker_id)
    blocked_id = get_field(changeset, :blocked_id)

    if blocker_id && blocked_id && blocker_id == blocked_id do
      add_error(changeset, :blocked_id, "cannot block yourself")
    else
      changeset
    end
  end
end
