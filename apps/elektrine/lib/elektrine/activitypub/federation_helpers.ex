defmodule Elektrine.ActivityPub.FederationHelpers do
  @moduledoc """
  Helper functions for testing and managing ActivityPub federation.
  """

  require Logger
  import Ecto.Query

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Builder, Fetcher, Publisher}
  alias Elektrine.Profiles
  alias Elektrine.Repo

  @doc """
  Follow a remote user from a local user.
  """
  def follow_remote_user(local_username, remote_handle) do
    with {:ok, local_user} <- get_local_user(local_username),
         {:ok, local_user} <- ActivityPub.KeyManager.ensure_user_has_keys(local_user),
         {:ok, acct} <- parse_remote_handle(remote_handle),
         {:ok, actor_uri} <- Fetcher.webfinger_lookup(acct),
         {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri) do
      # Check if already following (local user following remote actor)
      existing =
        from(f in Profiles.Follow,
          where: f.follower_id == ^local_user.id and f.remote_actor_id == ^remote_actor.id
        )
        |> Repo.one()

      if existing do
        {:error, :already_following}
      else
        # Build Follow activity
        follow_activity = Builder.build_follow_activity(local_user, remote_actor.uri)

        # Create pending follow relationship first
        {:ok, follow} =
          %Profiles.Follow{}
          |> Ecto.Changeset.change(%{
            follower_id: local_user.id,
            remote_actor_id: remote_actor.id,
            activitypub_id: follow_activity["id"],
            pending: true
          })
          |> Repo.insert()

        # Send to remote inbox
        Publisher.publish(follow_activity, local_user, [remote_actor.inbox_url])

        Logger.info("Sent Follow request to #{remote_handle}")

        {:ok,
         %{
           remote_actor: remote_actor,
           follow: follow
         }}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Unfollow a remote user.
  """
  def unfollow_remote_user(local_username, remote_handle) do
    with {:ok, local_user} <- get_local_user(local_username),
         {:ok, acct} <- parse_remote_handle(remote_handle),
         {:ok, actor_uri} <- Fetcher.webfinger_lookup(acct),
         {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri) do
      # Get the follow
      follow = Profiles.get_follow_by_remote_actor(remote_actor.id, local_user.id)

      if follow do
        # Build Undo activity
        original_follow = %{
          "id" => follow.activitypub_id,
          "type" => "Follow",
          "actor" => "#{ActivityPub.instance_url()}/users/#{local_user.username}",
          "object" => remote_actor.uri
        }

        undo_activity = Builder.build_undo_activity(local_user, original_follow)

        # Delete the follow
        Profiles.delete_remote_follow(remote_actor.id, local_user.id)

        # Send Undo to remote inbox
        Publisher.publish(undo_activity, local_user, [remote_actor.inbox_url])

        Logger.info("Unfollowed #{remote_handle}")
        {:ok, :unfollowed}
      else
        {:error, :not_following}
      end
    end
  end

  @doc """
  List all remote users being followed by a local user.
  """
  def list_remote_following(local_username) do
    case get_local_user(local_username) do
      {:ok, user} ->
        follows =
          from(f in Profiles.Follow,
            where: f.follower_id == ^user.id and not is_nil(f.remote_actor_id),
            preload: :remote_actor
          )
          |> Repo.all()

        remote_actors = Enum.map(follows, & &1.remote_actor)
        {:ok, remote_actors}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all remote users following a local user.
  """
  def list_remote_followers(local_username) do
    case get_local_user(local_username) do
      {:ok, user} ->
        follows =
          from(f in Profiles.Follow,
            where: f.followed_id == ^user.id and not is_nil(f.remote_actor_id),
            preload: :remote_actor
          )
          |> Repo.all()

        remote_actors = Enum.map(follows, & &1.remote_actor)
        {:ok, remote_actors}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get federated timeline for a user.
  Returns posts from remote users they follow.
  """
  def get_federated_timeline(local_username, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    case get_local_user(local_username) do
      {:ok, user} ->
        # Get remote actors the user follows
        remote_actor_ids =
          from(f in Profiles.Follow,
            where: f.follower_id == ^user.id and not is_nil(f.remote_actor_id),
            select: f.remote_actor_id
          )
          |> Repo.all()

        if remote_actor_ids == [] do
          {:ok, []}
        else
          # Get messages from those remote actors
          messages =
            from(m in Elektrine.Messaging.Message,
              where: m.federated == true and m.remote_actor_id in ^remote_actor_ids,
              where: is_nil(m.deleted_at),
              order_by: [desc: m.inserted_at],
              limit: ^limit,
              offset: ^offset,
              preload: :remote_actor
            )
            |> Repo.all()

          {:ok, messages}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get combined timeline (local + federated posts).
  """
  def get_combined_timeline(local_username, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    case get_local_user(local_username) do
      {:ok, user} ->
        # Get remote actors the user follows
        remote_actor_ids =
          from(f in Profiles.Follow,
            where: f.follower_id == ^user.id and not is_nil(f.remote_actor_id),
            select: f.remote_actor_id
          )
          |> Repo.all()

        # Get local users the user follows
        local_user_ids =
          from(f in Profiles.Follow,
            where: f.follower_id == ^user.id and not is_nil(f.followed_id),
            select: f.followed_id
          )
          |> Repo.all()

        # Query for combined posts
        query =
          from(m in Elektrine.Messaging.Message,
            where: is_nil(m.deleted_at),
            where: m.visibility in ["public", "unlisted"],
            order_by: [desc: m.inserted_at],
            limit: ^limit
          )

        # Filter to followed users or remote actors
        query =
          if remote_actor_ids != [] or local_user_ids != [] do
            from(m in query,
              where:
                (m.federated == true and m.remote_actor_id in ^remote_actor_ids) or
                  (m.federated == false and m.sender_id in ^local_user_ids) or
                  m.sender_id == ^user.id
            )
          else
            # No follows, just show own posts
            from(m in query, where: m.sender_id == ^user.id)
          end

        messages =
          query
          |> preload([:sender, :remote_actor])
          |> Repo.all()

        {:ok, messages}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get all public federated posts (discover feed).
  """
  def get_public_federated_posts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    messages =
      from(m in Elektrine.Messaging.Message,
        where: m.federated == true and m.visibility == "public",
        where: is_nil(m.deleted_at),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        offset: ^offset,
        preload: :remote_actor
      )
      |> Repo.all()

    {:ok, messages}
  end

  @doc """
  Show federation stats.
  """
  def federation_stats do
    %{
      remote_actors: Repo.aggregate(ActivityPub.Actor, :count, :id),
      activities_received:
        Repo.aggregate(
          from(a in ActivityPub.Activity, where: a.local == false),
          :count,
          :id
        ),
      activities_sent:
        Repo.aggregate(
          from(a in ActivityPub.Activity, where: a.local == true),
          :count,
          :id
        ),
      pending_deliveries: length(ActivityPub.get_pending_deliveries(1000)),
      federated_messages:
        Repo.aggregate(
          from(m in Elektrine.Messaging.Message, where: m.federated == true),
          :count,
          :id
        ),
      remote_followers:
        Repo.aggregate(
          from(f in Profiles.Follow, where: not is_nil(f.remote_actor_id)),
          :count,
          :id
        )
    }
  end

  ## Private helpers

  defp get_local_user(username) do
    case Accounts.get_user_by_username(username) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp parse_remote_handle(handle) do
    # Handle formats: user@domain.com or @user@domain.com
    handle = String.trim_leading(handle, "@")

    case String.split(handle, "@") do
      [username, domain] when username != "" and domain != "" ->
        {:ok, "#{username}@#{domain}"}

      _ ->
        {:error, :invalid_handle}
    end
  end
end
