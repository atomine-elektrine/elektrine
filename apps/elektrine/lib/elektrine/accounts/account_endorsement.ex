defmodule Elektrine.Accounts.AccountEndorsement do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "account_endorsements" do
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :endorsed_user, Elektrine.Accounts.User
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    timestamps(type: :utc_datetime)
  end

  def changeset(endorsement, attrs) do
    endorsement
    |> cast(attrs, [:user_id, :endorsed_user_id, :remote_actor_id])
    |> validate_required([:user_id])
    |> validate_exactly_one_target()
    |> validate_not_self()
    |> unique_constraint([:user_id, :endorsed_user_id],
      name: :account_endorsements_user_local_unique_idx
    )
    |> unique_constraint([:user_id, :remote_actor_id],
      name: :account_endorsements_user_remote_unique_idx
    )
    |> check_constraint(:endorsed_user_id, name: :account_endorsements_exactly_one_target)
    |> check_constraint(:endorsed_user_id, name: :account_endorsements_not_self)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:endorsed_user_id)
    |> foreign_key_constraint(:remote_actor_id)
  end

  defp validate_exactly_one_target(changeset) do
    local_id = get_field(changeset, :endorsed_user_id)
    remote_id = get_field(changeset, :remote_actor_id)

    case {local_id, remote_id} do
      {nil, nil} -> add_error(changeset, :endorsed_user_id, "must select an account")
      {_, nil} -> changeset
      {nil, _} -> changeset
      {_, _} -> add_error(changeset, :remote_actor_id, "cannot select multiple accounts")
    end
  end

  defp validate_not_self(changeset) do
    user_id = get_field(changeset, :user_id)
    endorsed_user_id = get_field(changeset, :endorsed_user_id)

    if user_id && endorsed_user_id && user_id == endorsed_user_id do
      add_error(changeset, :endorsed_user_id, "cannot endorse yourself")
    else
      changeset
    end
  end
end
