defmodule Elektrine.Accounts.Blocking do
  @moduledoc """
  User blocking functionality.
  Handles blocking, unblocking, and checking blocked relationships between users.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.{User, UserBlock}
  alias Elektrine.Repo

  @doc """
  Blocks a user.
  """
  def block_user(blocker_id, blocked_id, reason \\ nil) do
    %UserBlock{}
    |> UserBlock.changeset(%{
      blocker_id: blocker_id,
      blocked_id: blocked_id,
      reason: reason
    })
    |> Repo.insert()
  end

  @doc """
  Unblocks a user.
  """
  def unblock_user(blocker_id, blocked_id) do
    case Repo.get_by(UserBlock, blocker_id: blocker_id, blocked_id: blocked_id) do
      nil -> {:error, :not_blocked}
      block -> Repo.delete(block)
    end
  end

  @doc """
  Checks if a user is blocked by another user.
  """
  def user_blocked?(blocker_id, blocked_id) do
    Repo.exists?(
      from(ub in UserBlock,
        where: ub.blocker_id == ^blocker_id and ub.blocked_id == ^blocked_id
      )
    )
  end

  @doc """
  Gets all users blocked by a user.
  """
  def list_blocked_users(blocker_id) do
    from(u in User,
      join: ub in UserBlock,
      on: ub.blocked_id == u.id,
      where: ub.blocker_id == ^blocker_id,
      order_by: [desc: ub.inserted_at],
      preload: [:profile]
    )
    |> Repo.all()
  end

  @doc """
  Gets all users who have blocked a user.
  """
  def list_users_who_blocked(blocked_id) do
    from(u in User,
      join: ub in UserBlock,
      on: ub.blocker_id == u.id,
      where: ub.blocked_id == ^blocked_id,
      select: u
    )
    |> Repo.all()
  end

  @doc """
  Blocks a remote actor (ActivityPub federation).
  """
  def block_remote_actor(user_id, remote_actor_id) do
    alias Elektrine.ActivityPub.UserBlock

    # Get remote actor URI
    remote_actor = Elektrine.Repo.get(Elektrine.ActivityPub.Actor, remote_actor_id)

    if remote_actor do
      # Create block record
      result =
        %UserBlock{}
        |> UserBlock.changeset(%{
          user_id: user_id,
          blocked_uri: remote_actor.uri,
          block_type: "user"
        })
        |> Repo.insert()

      case result do
        {:ok, block} ->
          # Federate Block activity
          Task.start(fn ->
            user = Elektrine.Accounts.get_user!(user_id)

            block_activity =
              Elektrine.ActivityPub.Builder.build_block_activity(user, remote_actor.uri)

            Elektrine.ActivityPub.Publisher.publish(block_activity, user, [remote_actor.inbox_url])
          end)

          {:ok, block}

        error ->
          error
      end
    else
      {:error, :remote_actor_not_found}
    end
  end

  @doc """
  Unblocks a remote actor (ActivityPub federation).
  """
  def unblock_remote_actor(user_id, remote_actor_id) do
    alias Elektrine.ActivityPub.UserBlock

    # Get remote actor URI
    remote_actor = Elektrine.Repo.get(Elektrine.ActivityPub.Actor, remote_actor_id)

    if remote_actor do
      # Delete block record
      case Repo.get_by(UserBlock, user_id: user_id, blocked_uri: remote_actor.uri) do
        nil ->
          {:error, :not_blocked}

        block ->
          result = Repo.delete(block)

          case result do
            {:ok, _deleted_block} ->
              # Federate Undo Block activity
              Task.start(fn ->
                user = Elektrine.Accounts.get_user!(user_id)

                # Build original Block activity
                original_block = %{
                  "type" => "Block",
                  "actor" => "#{Elektrine.ActivityPub.instance_url()}/users/#{user.username}",
                  "object" => remote_actor.uri
                }

                undo_activity =
                  Elektrine.ActivityPub.Builder.build_undo_activity(user, original_block)

                Elektrine.ActivityPub.Publisher.publish(undo_activity, user, [
                  remote_actor.inbox_url
                ])
              end)

              {:ok, :unblocked}

            error ->
              error
          end
      end
    else
      {:error, :remote_actor_not_found}
    end
  end

  @doc """
  Checks if a user has blocked a remote actor.
  """
  def remote_actor_blocked?(user_id, remote_actor_id) do
    alias Elektrine.ActivityPub.UserBlock

    remote_actor = Elektrine.Repo.get(Elektrine.ActivityPub.Actor, remote_actor_id)

    if remote_actor do
      Repo.exists?(
        from(ub in UserBlock,
          where: ub.user_id == ^user_id and ub.blocked_uri == ^remote_actor.uri
        )
      )
    else
      false
    end
  end

  @doc """
  Lists all remote actors blocked by a user.
  """
  def list_blocked_remote_actors(user_id) do
    alias Elektrine.ActivityPub.UserBlock

    from(ub in UserBlock,
      where: ub.user_id == ^user_id and ub.block_type == "user",
      order_by: [desc: ub.inserted_at]
    )
    |> Repo.all()
  end
end
