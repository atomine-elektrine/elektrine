defmodule Elektrine.ActivityPub.Handlers.FollowHandler do
  @moduledoc """
  Handles Follow, Accept, and Reject ActivityPub activities.
  """

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Builder, Publisher, Relay}
  alias Elektrine.Profiles

  @doc """
  Handles an incoming Follow activity.
  """
  def handle(
        %{"id" => follow_id, "actor" => actor_uri, "object" => object_uri},
        actor_uri,
        _target_user
      ) do
    # Get or fetch the remote actor (create mock in dev for testing)
    remote_actor_result =
      if Application.get_env(:elektrine, :env) == :dev do
        case ActivityPub.get_or_fetch_actor(actor_uri) do
          {:ok, actor} ->
            {:ok, actor}

          {:error, _} ->
            # Create and save a minimal mock actor for testing
            uri = URI.parse(actor_uri)

            Elektrine.Repo.insert(
              %ActivityPub.Actor{
                uri: actor_uri,
                username: "testuser",
                domain: uri.host,
                inbox_url: "#{actor_uri}/inbox",
                public_key:
                  "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
                last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
                metadata: %{"mock" => true}
              },
              on_conflict: :nothing
            )
        end
      else
        ActivityPub.get_or_fetch_actor(actor_uri)
      end

    with {:ok, remote_actor} <- remote_actor_result do
      # Check if target is our relay actor (dynamic URL check)
      relay_url = Relay.relay_actor_id()

      cond do
        # Target is our relay actor - relays following us
        object_uri == relay_url ->
          Logger.info("Relay #{actor_uri} wants to follow our relay")
          # Auto-accept relay follows - send Accept back
          {:ok, relay_actor} = Relay.get_or_create_relay_actor()
          send_relay_accept(relay_actor, remote_actor, follow_id)
          {:ok, :relay_follow_accepted}

        # Check if target is a local Group actor (community)
        group_actor = ActivityPub.get_local_group_actor_by_uri(object_uri) ->
          handle_group_follow(remote_actor, group_actor, follow_id, actor_uri)

        # Default to user follow
        true ->
          handle_user_follow(remote_actor, object_uri, follow_id, actor_uri)
      end
    else
      error ->
        Logger.error("Failed to handle follow: #{inspect(error)}")
        {:error, :handle_follow_failed}
    end
  end

  @doc """
  Handles an incoming Accept activity for a Follow.
  """
  def handle_accept(
        %{"object" => %{"type" => "Follow", "id" => follow_id}} = _activity,
        actor_uri,
        _target_user
      ) do
    Logger.debug(
      "FollowHandler: Received Accept with Follow object, id=#{follow_id}, actor=#{actor_uri}"
    )

    # First check if this is a relay subscription Accept
    case Relay.handle_accept(follow_id) do
      {:ok, _subscription} ->
        {:ok, :relay_subscription_accepted}

      {:error, :subscription_not_found} ->
        # Try matching by actor URI (some relays send Accept from their actor)
        case Relay.handle_accept_from_actor(actor_uri) do
          {:ok, _subscription} ->
            {:ok, :relay_subscription_accepted}

          {:error, :subscription_not_found} ->
            # Not a relay, check for regular user follow
            handle_user_accept(follow_id)
        end
    end
  end

  # Handle Accept where object is just a string (the Follow activity ID)
  # Some relay implementations send Accept with just the object ID as a string
  def handle_accept(
        %{"object" => follow_id} = _activity,
        actor_uri,
        _target_user
      )
      when is_binary(follow_id) do
    Logger.debug(
      "FollowHandler: Received Accept with string object=#{follow_id}, actor=#{actor_uri}"
    )

    # Check if this is a relay subscription Accept
    case Relay.handle_accept(follow_id) do
      {:ok, _subscription} ->
        {:ok, :relay_subscription_accepted}

      {:error, :subscription_not_found} ->
        # Try matching by actor URI
        case Relay.handle_accept_from_actor(actor_uri) do
          {:ok, _subscription} ->
            {:ok, :relay_subscription_accepted}

          {:error, :subscription_not_found} ->
            # Not a relay, check for regular user follow
            handle_user_accept(follow_id)
        end
    end
  end

  def handle_accept(_activity, _actor_uri, _target_user), do: {:ok, :unhandled}

  # Helper for handling user follow accepts
  defp handle_user_accept(follow_id) do
    case ActivityPub.get_activity_by_id(follow_id) do
      nil ->
        Logger.warning("Received Accept for unknown Follow: #{follow_id}")
        {:ok, :unknown_follow}

      activity ->
        if activity.internal_user_id do
          Profiles.accept_follow_by_activity_id(follow_id)

          Task.start(fn ->
            Elektrine.Notifications.FederationNotifications.notify_follow_accepted(
              activity.internal_user_id,
              activity.object_id
            )
          end)

          {:ok, :follow_accepted}
        else
          {:ok, :not_our_follow}
        end
    end
  end

  @doc """
  Handles an incoming Reject activity for a Follow.
  """
  def handle_reject(
        %{"object" => %{"type" => "Follow", "id" => follow_id}},
        _actor_uri,
        _target_user
      ) do
    # First check if this is a relay subscription Reject
    case Relay.handle_reject(follow_id) do
      {:ok, _subscription} ->
        {:ok, :relay_subscription_rejected}

      {:error, :subscription_not_found} ->
        # Not a relay, check for regular user follow
        case ActivityPub.get_activity_by_id(follow_id) do
          nil ->
            {:ok, :unknown_follow}

          activity ->
            if activity.internal_user_id do
              Profiles.delete_follow_by_activity_id(follow_id)
              {:ok, :follow_rejected}
            else
              {:ok, :not_our_follow}
            end
        end
    end
  end

  def handle_reject(_activity, _actor_uri, _target_user), do: {:ok, :unhandled}

  @doc """
  Handles Undo Follow activity.
  """
  def handle_undo(%{"object" => followed_uri}, actor_uri) when is_binary(followed_uri) do
    with {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri) do
      case ActivityPub.get_local_group_actor_by_uri(followed_uri) do
        nil ->
          case get_local_user_from_uri(followed_uri) do
            {:ok, followed_user} ->
              Profiles.delete_remote_follow(remote_actor.id, followed_user.id)
              {:ok, :unfollowed}

            {:error, _} ->
              {:ok, :target_not_found}
          end

        group_actor ->
          ActivityPub.delete_group_follow(remote_actor.id, group_actor.id)
          {:ok, :unfollowed}
      end
    else
      {:error, reason} ->
        Logger.warning("Failed to process Undo Follow from #{actor_uri}: #{inspect(reason)}")
        {:error, :undo_follow_failed}
    end
  end

  def handle_undo(%{"object" => followed_uri} = _follow_object, actor_uri)
      when is_map(followed_uri) do
    uri = followed_uri["id"] || followed_uri
    handle_undo(%{"object" => uri}, actor_uri)
  end

  def handle_undo(_object, actor_uri) do
    Logger.warning("Invalid Undo Follow from #{actor_uri}")
    {:ok, :invalid}
  end

  # Private functions

  defp handle_user_follow(remote_actor, object_uri, follow_id, _actor_uri) do
    case get_local_user_from_uri(object_uri) do
      {:ok, followed_user} ->
        existing_follow = Profiles.get_follow_by_remote_actor(remote_actor.id, followed_user.id)

        if existing_follow do
          if existing_follow.pending do
            # Keep pending requests pending until explicitly approved by the local user.
            {:ok, :pending}
          else
            send_accept(followed_user, remote_actor, existing_follow)
            {:ok, :already_following}
          end
        else
          pending = followed_user.activitypub_manually_approve_followers

          case Profiles.create_remote_follow(
                 remote_actor.id,
                 followed_user.id,
                 pending,
                 follow_id
               ) do
            {:ok, follow} ->
              if pending do
                Task.start(fn ->
                  Elektrine.Notifications.FederationNotifications.notify_remote_follow(
                    followed_user.id,
                    remote_actor.id
                  )
                end)

                {:ok, :pending}
              else
                send_accept(followed_user, remote_actor, follow)

                Task.start(fn ->
                  Elektrine.Notifications.FederationNotifications.notify_remote_follow(
                    followed_user.id,
                    remote_actor.id
                  )
                end)

                {:ok, :accepted}
              end

            {:error, reason} ->
              Logger.error("Failed to create follow: #{inspect(reason)}")
              {:error, :failed_to_create_follow}
          end
        end

      {:error, _} ->
        Logger.error("Follow target not found: #{object_uri}")
        {:error, :target_not_found}
    end
  end

  defp handle_group_follow(remote_actor, group_actor, follow_id, _actor_uri) do
    existing_follow = ActivityPub.get_group_follow(remote_actor.id, group_actor.id)

    if existing_follow do
      send_group_accept(group_actor, remote_actor, existing_follow)
      {:ok, :already_following}
    else
      case ActivityPub.create_group_follow(remote_actor.id, group_actor.id, follow_id, false) do
        {:ok, follow} ->
          send_group_accept(group_actor, remote_actor, follow)
          {:ok, :accepted}

        {:error, reason} ->
          Logger.error("Failed to create group follow: #{inspect(reason)}")
          {:error, :failed_to_create_follow}
      end
    end
  end

  defp send_accept(user, remote_actor, follow) do
    accept_activity =
      Builder.build_accept_activity(user, %{
        "id" => follow.activitypub_id,
        "type" => "Follow",
        "actor" => remote_actor.uri,
        "object" => "#{ActivityPub.instance_url()}/users/#{user.username}"
      })

    Publisher.publish(accept_activity, user, [remote_actor.inbox_url])
  end

  defp send_group_accept(group_actor, remote_actor, follow) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    accept_activity = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Accept",
      "actor" => group_actor.uri,
      "object" => %{
        "id" => follow.activitypub_id,
        "type" => "Follow",
        "actor" => remote_actor.uri,
        "object" => group_actor.uri
      }
    }

    Publisher.publish(accept_activity, nil, [remote_actor.inbox_url])
  end

  defp send_relay_accept(relay_actor, remote_actor, follow_id) do
    base_url = ActivityPub.instance_url()
    relay_url = Relay.relay_actor_id()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    accept_activity = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Accept",
      "actor" => relay_url,
      "object" => %{
        "id" => follow_id,
        "type" => "Follow",
        "actor" => remote_actor.uri,
        "object" => relay_url
      }
    }

    Publisher.deliver(accept_activity, relay_actor, remote_actor.inbox_url)
  end

  defp get_local_user_from_uri(uri) do
    base_url = ActivityPub.instance_url()

    cond do
      String.starts_with?(uri, "#{base_url}/users/") ->
        username = String.replace_prefix(uri, "#{base_url}/users/", "")

        case Elektrine.Accounts.get_user_by_username(username) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end

      String.starts_with?(uri, "#{base_url}/@") ->
        username = String.replace_prefix(uri, "#{base_url}/@", "")

        case Elektrine.Accounts.get_user_by_username(username) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end

      true ->
        {:error, :not_local}
    end
  end
end
