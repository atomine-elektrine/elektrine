defmodule Elektrine.Profiles.Follow do
  @moduledoc """
  Schema representing follower/followed relationships between users.
  Prevents self-following and enforces unique follow relationships.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "follows" do
    belongs_to :follower, Elektrine.Accounts.User
    belongs_to :followed, Elektrine.Accounts.User
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    field :activitypub_id, :string
    field :pending, :boolean, default: false

    timestamps()
  end

  @doc false
  def changeset(follow, attrs) do
    follow
    |> cast(attrs, [:follower_id, :followed_id, :remote_actor_id, :activitypub_id, :pending])
    |> validate_required_relationship()
    |> validate_not_self_follow()
    |> unique_constraint([:follower_id, :followed_id])
  end

  # Validate that the relationship makes sense
  defp validate_required_relationship(changeset) do
    follower_id = get_field(changeset, :follower_id)
    followed_id = get_field(changeset, :followed_id)
    remote_actor_id = get_field(changeset, :remote_actor_id)

    cond do
      # Case 1: Local user follows local user (normal follow)
      not is_nil(follower_id) and not is_nil(followed_id) and is_nil(remote_actor_id) ->
        changeset

      # Case 2: Remote user follows local user
      is_nil(follower_id) and not is_nil(followed_id) and not is_nil(remote_actor_id) ->
        changeset

      # Case 3: Local user follows remote user
      not is_nil(follower_id) and is_nil(followed_id) and not is_nil(remote_actor_id) ->
        changeset

      true ->
        add_error(
          changeset,
          :base,
          "invalid follow relationship: must be local-local, remote-local, or local-remote"
        )
    end
  end

  defp validate_not_self_follow(changeset) do
    follower_id = get_field(changeset, :follower_id)
    followed_id = get_field(changeset, :followed_id)

    if follower_id == followed_id do
      add_error(changeset, :followed_id, "cannot follow yourself")
    else
      changeset
    end
  end
end
