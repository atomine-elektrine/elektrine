defmodule Elektrine.ActivityPub.Handlers.FollowHandler do
  @moduledoc "Handles Follow, Accept, and Reject ActivityPub activities.\n"
  require Logger
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Builder, Publisher, Relay}
  alias Elektrine.Async
  alias Elektrine.Profiles
  alias Elektrine.RuntimeEnv
  @doc "Handles an incoming Follow activity.\n"
  def handle(
        %{"id" => follow_id, "actor" => actor_uri, "object" => object_ref},
        actor_uri,
        _target_user
      ) do
    case resolve_follow_target_uri(object_ref) do
      object_uri when is_binary(object_uri) and object_uri != "" ->
        remote_actor_result =
          if RuntimeEnv.environment() == :dev do
            case ActivityPub.get_or_fetch_actor(actor_uri) do
              {:ok, actor} ->
                {:ok, actor}

              {:error, _} ->
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

        case remote_actor_result do
          {:ok, remote_actor} ->
            relay_url = Relay.relay_actor_id()

            cond do
              object_uri == relay_url ->
                Logger.info("Relay #{actor_uri} wants to follow our relay")
                {:ok, relay_actor} = Relay.get_or_create_relay_actor()
                send_relay_accept(relay_actor, remote_actor, follow_id)
                {:ok, :relay_follow_accepted}

              group_actor = ActivityPub.get_local_group_actor_by_uri(object_uri) ->
                handle_group_follow(remote_actor, group_actor, follow_id, actor_uri)

              true ->
                handle_user_follow(remote_actor, object_uri, follow_id, actor_uri)
            end

          error ->
            Logger.error("Failed to handle follow: #{inspect(error)}")
            {:error, :handle_follow_failed}
        end

      _ ->
        Logger.warning("Invalid Follow target from #{actor_uri}: #{inspect(object_ref)}")
        {:error, :handle_follow_failed}
    end
  end

  @doc "Handles an incoming Accept activity for a Follow.\n"
  def handle_accept(
        %{"object" => %{"type" => "Follow", "id" => follow_id}} = _activity,
        actor_uri,
        _target_user
      ) do
    Logger.debug(
      "FollowHandler: Received Accept with Follow object, id=#{follow_id}, actor=#{actor_uri}"
    )

    case Relay.handle_accept(follow_id, actor_uri) do
      {:ok, _subscription} ->
        {:ok, :relay_subscription_accepted}

      {:error, :subscription_not_found} ->
        case Relay.handle_accept_from_actor(actor_uri) do
          {:ok, _subscription} -> {:ok, :relay_subscription_accepted}
          {:error, :subscription_not_found} -> handle_user_accept(follow_id, actor_uri)
        end
    end
  end

  def handle_accept(
        %{"object" => follow_id} = _activity,
        actor_uri,
        _target_user
      )
      when is_binary(follow_id) do
    Logger.debug(
      "FollowHandler: Received Accept with string object=#{follow_id}, actor=#{actor_uri}"
    )

    case Relay.handle_accept(follow_id, actor_uri) do
      {:ok, _subscription} ->
        {:ok, :relay_subscription_accepted}

      {:error, :subscription_not_found} ->
        case Relay.handle_accept_from_actor(actor_uri) do
          {:ok, _subscription} -> {:ok, :relay_subscription_accepted}
          {:error, :subscription_not_found} -> handle_user_accept(follow_id, actor_uri)
        end
    end
  end

  def handle_accept(_activity, _actor_uri, _target_user) do
    {:ok, :unhandled}
  end

  defp handle_user_accept(follow_id, actor_uri) do
    case ActivityPub.get_activity_by_id(follow_id) do
      nil ->
        Logger.warning("Received Accept for unknown Follow: #{follow_id}")
        {:ok, :unknown_follow}

      activity ->
        cond do
          !activity.internal_user_id ->
            {:ok, :not_our_follow}

          !follow_target_matches_actor?(activity, actor_uri) ->
            Logger.warning(
              "Rejecting Accept for Follow #{follow_id}: actor #{actor_uri} does not match original follow target #{activity.object_id}"
            )

            {:ok, :unauthorized}

          true ->
            Profiles.accept_follow_by_activity_id(follow_id)

            Async.run(fn ->
              Elektrine.Notifications.FederationNotifications.notify_follow_accepted(
                activity.internal_user_id,
                activity.object_id
              )
            end)

            {:ok, :follow_accepted}
        end
    end
  end

  @doc "Handles an incoming Reject activity for a Follow.\n"
  def handle_reject(
        %{"object" => %{"type" => "Follow", "id" => follow_id}},
        actor_uri,
        _target_user
      ) do
    handle_reject_by_id(follow_id, actor_uri)
  end

  def handle_reject(
        %{"object" => follow_id},
        actor_uri,
        _target_user
      )
      when is_binary(follow_id) do
    handle_reject_by_id(follow_id, actor_uri)
  end

  def handle_reject(_activity, _actor_uri, _target_user) do
    {:ok, :unhandled}
  end

  defp handle_reject_by_id(follow_id, actor_uri) do
    case Relay.handle_reject(follow_id, actor_uri) do
      {:ok, _subscription} ->
        {:ok, :relay_subscription_rejected}

      {:error, :subscription_not_found} ->
        case ActivityPub.get_activity_by_id(follow_id) do
          nil ->
            {:ok, :unknown_follow}

          activity ->
            cond do
              !activity.internal_user_id ->
                {:ok, :not_our_follow}

              !follow_target_matches_actor?(activity, actor_uri) ->
                Logger.warning(
                  "Rejecting Reject for Follow #{follow_id}: actor #{actor_uri} does not match original follow target #{activity.object_id}"
                )

                {:ok, :unauthorized}

              true ->
                Profiles.delete_follow_by_activity_id(follow_id)
                {:ok, :follow_rejected}
            end
        end
    end
  end

  @doc "Handles Undo Follow activity.\n"
  def handle_undo(%{"object" => followed_uri}, actor_uri) when is_binary(followed_uri) do
    case ActivityPub.get_or_fetch_actor(actor_uri) do
      {:ok, remote_actor} ->
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

      {:error, reason} ->
        Logger.warning("Failed to process Undo Follow from #{actor_uri}: #{inspect(reason)}")
        {:error, :undo_follow_failed}
    end
  end

  def handle_undo(%{"object" => followed_uri} = _follow_object, actor_uri)
      when is_map(followed_uri) do
    case resolve_follow_target_uri(followed_uri) do
      uri when is_binary(uri) and uri != "" ->
        handle_undo(%{"object" => uri}, actor_uri)

      _ ->
        Logger.warning("Invalid Undo Follow from #{actor_uri}")
        {:ok, :invalid}
    end
  end

  def handle_undo(_object, actor_uri) do
    Logger.warning("Invalid Undo Follow from #{actor_uri}")
    {:ok, :invalid}
  end

  defp follow_target_matches_actor?(%{object_id: object_id}, actor_uri)
       when is_binary(object_id) and is_binary(actor_uri) do
    normalize_actor_uri(object_id) == normalize_actor_uri(actor_uri)
  end

  defp follow_target_matches_actor?(_, _), do: false

  defp normalize_actor_uri(uri) when is_binary(uri) do
    uri
    |> String.trim()
    |> String.split("#", parts: 2)
    |> hd()
    |> String.split("?", parts: 2)
    |> hd()
    |> String.trim_trailing("/")
  end

  defp resolve_follow_target_uri(uri) when is_binary(uri), do: uri

  defp resolve_follow_target_uri(%{"object" => object_ref}) do
    resolve_follow_target_uri(object_ref)
  end

  defp resolve_follow_target_uri(%{"id" => id}) when is_binary(id), do: id
  defp resolve_follow_target_uri(_), do: nil

  defp handle_user_follow(remote_actor, object_uri, follow_id, _actor_uri) do
    case get_local_user_from_uri(object_uri) do
      {:ok, followed_user} ->
        existing_follow = Profiles.get_follow_by_remote_actor(remote_actor.id, followed_user.id)

        if existing_follow do
          if existing_follow.pending do
            {:ok, :pending}
          else
            send_accept(followed_user, remote_actor, follow_id, object_uri)
            {:ok, :already_following}
          end
        else
          pending =
            followed_user.activitypub_manually_approve_followers ||
              followed_user.profile_visibility in ["followers", "private"]

          case Profiles.create_remote_follow(
                 remote_actor.id,
                 followed_user.id,
                 pending,
                 follow_id
               ) do
            {:ok, _follow} ->
              if pending do
                Async.run(fn ->
                  Elektrine.Notifications.FederationNotifications.notify_remote_follow(
                    followed_user.id,
                    remote_actor.id
                  )
                end)

                {:ok, :pending}
              else
                send_accept(followed_user, remote_actor, follow_id, object_uri)

                Async.run(fn ->
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
      send_group_accept(group_actor, remote_actor, follow_id)
      {:ok, :already_following}
    else
      case ActivityPub.create_group_follow(remote_actor.id, group_actor.id, follow_id, false) do
        {:ok, _follow} ->
          send_group_accept(group_actor, remote_actor, follow_id)
          {:ok, :accepted}

        {:error, reason} ->
          Logger.error("Failed to create group follow: #{inspect(reason)}")
          {:error, :failed_to_create_follow}
      end
    end
  end

  defp send_accept(user, remote_actor, follow_id, object_uri) when is_binary(follow_id) do
    target_uri = object_uri || ActivityPub.actor_uri(user)

    accept_activity =
      Builder.build_accept_activity(user, %{
        "id" => follow_id,
        "type" => "Follow",
        "actor" => remote_actor.uri,
        "object" => target_uri
      })

    Publisher.publish(accept_activity, user, [remote_actor.inbox_url])
  end

  defp send_group_accept(group_actor, remote_actor, follow_id) when is_binary(follow_id) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    accept_activity = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Accept",
      "actor" => group_actor.uri,
      "object" => %{
        "id" => follow_id,
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
    case ActivityPub.local_username_from_uri(uri) do
      {:ok, username} ->
        case Elektrine.Accounts.get_user_by_username(username) do
          %{activitypub_enabled: true} = user -> {:ok, user}
          _ -> {:error, :not_found}
        end

      {:error, _reason} ->
        {:error, :not_local}
    end
  end
end
