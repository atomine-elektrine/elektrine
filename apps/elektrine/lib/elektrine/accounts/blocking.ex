defmodule Elektrine.Accounts.Blocking do
  @moduledoc """
  User blocking functionality.
  Handles blocking, unblocking, and checking blocked relationships between users.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.{User, UserBlock}
  alias Elektrine.ActivityPub.UserBlock, as: ActivityPubUserBlock
  alias Elektrine.Repo

  @doc """
  Blocks a user.
  """
  def block_user(blocker_id, blocked_id, reason \\ nil) do
    result =
      %UserBlock{}
      |> UserBlock.changeset(%{
        blocker_id: blocker_id,
        blocked_id: blocked_id,
        reason: reason
      })
      |> Repo.insert()

    notify_home_feed_policy_changed(blocker_id, :blocked_user)
    result
  end

  @doc """
  Unblocks a user.
  """
  def unblock_user(blocker_id, blocked_id) do
    result =
      case Repo.get_by(UserBlock, blocker_id: blocker_id, blocked_id: blocked_id) do
        nil -> {:error, :not_blocked}
        block -> Repo.delete(block)
      end

    notify_home_feed_policy_changed(blocker_id, :unblocked_user)
    result
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
          Elektrine.Async.start(fn ->
            user = Elektrine.Accounts.get_user!(user_id)

            block_activity =
              Elektrine.ActivityPub.Builder.build_block_activity(user, remote_actor.uri)

            Elektrine.ActivityPub.Publisher.publish(block_activity, user, [remote_actor.inbox_url])
          end)

          notify_home_feed_policy_changed(user_id, :blocked_remote_actor)
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
              Elektrine.Async.start(fn ->
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

              notify_home_feed_policy_changed(user_id, :unblocked_remote_actor)
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
          where:
            ub.user_id == ^user_id and ub.blocked_uri == ^remote_actor.uri and
              ub.block_type == "user"
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
    from(ub in ActivityPubUserBlock,
      where: ub.user_id == ^user_id and ub.block_type == "user",
      order_by: [desc: ub.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Mutes a remote actor for local timelines and notifications.
  """
  def mute_remote_actor(user_id, remote_actor_id) do
    case Elektrine.Repo.get(Elektrine.ActivityPub.Actor, remote_actor_id) do
      nil ->
        {:error, :remote_actor_not_found}

      remote_actor ->
        result =
          case Repo.get_by(ActivityPubUserBlock,
                 user_id: user_id,
                 blocked_uri: remote_actor.uri
               ) do
            nil ->
              %ActivityPubUserBlock{}
              |> ActivityPubUserBlock.changeset(%{
                user_id: user_id,
                blocked_uri: remote_actor.uri,
                block_type: "mute"
              })
              |> Repo.insert()

            %ActivityPubUserBlock{} = existing ->
              {:ok, existing}
          end

        notify_home_feed_policy_changed(user_id, :muted_remote_actor)
        result
    end
  end

  @doc """
  Unmutes a remote actor.
  """
  def unmute_remote_actor(user_id, remote_actor_id) do
    case Elektrine.Repo.get(Elektrine.ActivityPub.Actor, remote_actor_id) do
      nil ->
        {:error, :remote_actor_not_found}

      remote_actor ->
        result =
          case Repo.get_by(ActivityPubUserBlock,
                 user_id: user_id,
                 blocked_uri: remote_actor.uri,
                 block_type: "mute"
               ) do
            nil -> {:error, :not_muted}
            mute -> Repo.delete(mute)
          end

        notify_home_feed_policy_changed(user_id, :unmuted_remote_actor)
        result
    end
  end

  @doc """
  Checks if a user has muted a remote actor.
  """
  def remote_actor_muted?(user_id, remote_actor_id) do
    case Elektrine.Repo.get(Elektrine.ActivityPub.Actor, remote_actor_id) do
      nil ->
        false

      remote_actor ->
        Repo.exists?(
          from ub in ActivityPubUserBlock,
            where:
              ub.user_id == ^user_id and ub.blocked_uri == ^remote_actor.uri and
                ub.block_type == "mute"
        )
    end
  end

  @doc """
  Lists all remote actor mutes for a user.
  """
  def list_muted_remote_actors(user_id) do
    from(ub in ActivityPubUserBlock,
      where: ub.user_id == ^user_id and ub.block_type == "mute",
      order_by: [desc: ub.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Blocks a remote domain for a specific user.
  """
  def block_domain(user_id, domain) when is_integer(user_id) and is_binary(domain) do
    with {:ok, domain} <- normalize_domain_block(domain) do
      result =
        case Repo.get_by(ActivityPubUserBlock, user_id: user_id, blocked_uri: domain) do
          nil ->
            %ActivityPubUserBlock{}
            |> ActivityPubUserBlock.changeset(%{
              user_id: user_id,
              blocked_uri: domain,
              block_type: "domain"
            })
            |> Repo.insert()

          %ActivityPubUserBlock{} = block ->
            {:ok, block}
        end

      notify_home_feed_policy_changed(user_id, :blocked_domain)
      result
    end
  end

  def block_domain(_user_id, _domain), do: {:error, :invalid_domain}

  @doc """
  Unblocks a remote domain for a specific user.
  """
  def unblock_domain(user_id, domain) when is_integer(user_id) and is_binary(domain) do
    with {:ok, domain} <- normalize_domain_block(domain) do
      result =
        case Repo.get_by(ActivityPubUserBlock,
               user_id: user_id,
               blocked_uri: domain,
               block_type: "domain"
             ) do
          nil -> {:ok, :not_blocked}
          block -> Repo.delete(block)
        end

      notify_home_feed_policy_changed(user_id, :unblocked_domain)
      result
    end
  end

  def unblock_domain(_user_id, _domain), do: {:error, :invalid_domain}

  @doc """
  Lists remote domains blocked by a specific user.
  """
  def list_blocked_domains(user_id) when is_integer(user_id) do
    from(ub in ActivityPubUserBlock,
      where: ub.user_id == ^user_id and ub.block_type == "domain",
      order_by: [asc: ub.blocked_uri],
      select: ub.blocked_uri
    )
    |> Repo.all()
  end

  def list_blocked_domains(_user_id), do: []

  @doc """
  Checks whether a remote domain is blocked by a user.
  """
  def domain_blocked?(user_id, domain) when is_integer(user_id) and is_binary(domain) do
    Repo.exists?(
      from ub in ActivityPubUserBlock,
        where: ub.user_id == ^user_id and ub.block_type == "domain",
        where:
          fragment("lower(?)", ub.blocked_uri) == fragment("lower(?)", ^domain) or
            fragment(
              "? LIKE '*.%' AND lower(?) LIKE ('%.' || substring(lower(?) from 3))",
              ub.blocked_uri,
              ^domain,
              ub.blocked_uri
            )
    )
  end

  def domain_blocked?(_user_id, _domain), do: false

  defp normalize_domain_block(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.trim_leading("@")
      |> String.downcase()

    value =
      case URI.parse(value) do
        %URI{host: host} when is_binary(host) -> host
        _ -> value
      end

    wildcard? = String.starts_with?(value, "*.")
    domain = if wildcard?, do: String.trim_leading(value, "*."), else: value
    domain = domain |> String.split("/", parts: 2) |> List.first() |> String.trim(".")

    cond do
      domain == "" ->
        {:error, :invalid_domain}

      not Regex.match?(~r/^[a-z0-9.-]+$/, domain) ->
        {:error, :invalid_domain}

      String.contains?(domain, "..") ->
        {:error, :invalid_domain}

      not String.contains?(domain, ".") ->
        {:error, :invalid_domain}

      wildcard? ->
        {:ok, "*." <> domain}

      true ->
        {:ok, domain}
    end
  end

  defp notify_home_feed_policy_changed(user_id, reason) when is_integer(user_id) do
    module = Module.concat([Elektrine, Social, HomeFeedInvalidationWorker])

    if Code.ensure_loaded?(module) do
      _ = module.clear_user(user_id, reason)
    end

    :ok
  rescue
    _ -> :ok
  end
end
