defmodule Elektrine.Accounts.InviteCodeUse do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "invite_code_uses" do
    belongs_to :invite_code, Elektrine.Accounts.InviteCode
    belongs_to :user, Elektrine.Accounts.User
    field :used_at, :utc_datetime
  end

  @doc false
  def changeset(invite_code_use, attrs) do
    invite_code_use
    |> cast(attrs, [:invite_code_id, :user_id])
    |> validate_required([:invite_code_id, :user_id])
    |> foreign_key_constraint(:invite_code_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id, name: :invite_code_uses_user_id_unique)
  end
end
