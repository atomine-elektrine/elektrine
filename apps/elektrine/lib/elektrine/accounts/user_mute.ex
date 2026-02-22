defmodule Elektrine.Accounts.UserMute do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_mutes" do
    belongs_to :muter, Elektrine.Accounts.User
    belongs_to :muted, Elektrine.Accounts.User
    field :mute_notifications, :boolean, default: false

    timestamps()
  end

  @doc false
  def changeset(user_mute, attrs) do
    user_mute
    |> cast(attrs, [:muter_id, :muted_id, :mute_notifications])
    |> validate_required([:muter_id, :muted_id])
    |> validate_not_self_mute()
    |> unique_constraint([:muter_id, :muted_id])
    |> foreign_key_constraint(:muter_id)
    |> foreign_key_constraint(:muted_id)
  end

  defp validate_not_self_mute(changeset) do
    muter_id = get_field(changeset, :muter_id)
    muted_id = get_field(changeset, :muted_id)

    if muter_id && muted_id && muter_id == muted_id do
      add_error(changeset, :muted_id, "cannot mute yourself")
    else
      changeset
    end
  end
end
