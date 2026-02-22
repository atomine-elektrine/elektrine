defmodule Elektrine.Social.ListMember do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "list_members" do
    belongs_to :list, Elektrine.Social.List
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    timestamps()
  end

  @doc false
  def changeset(list_member, attrs) do
    list_member
    |> cast(attrs, [:list_id, :user_id, :remote_actor_id])
    |> validate_required([:list_id])
    |> validate_user_or_remote_actor()
    |> unique_constraint([:list_id, :user_id])
    |> unique_constraint([:list_id, :remote_actor_id])
  end

  defp validate_user_or_remote_actor(changeset) do
    user_id = get_field(changeset, :user_id)
    remote_actor_id = get_field(changeset, :remote_actor_id)

    cond do
      user_id && remote_actor_id ->
        add_error(changeset, :base, "Cannot have both user_id and remote_actor_id")

      !user_id && !remote_actor_id ->
        add_error(changeset, :base, "Must have either user_id or remote_actor_id")

      true ->
        changeset
    end
  end
end
