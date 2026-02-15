defmodule Elektrine.ActivityPub.Relay do
  @moduledoc """
  Manages ActivityPub relay subscriptions.

  A relay is a special actor that rebroadcasts content from all instances
  that follow it. This allows smaller instances to discover content from
  a wider network without directly following thousands of individual accounts.

  ## How Relays Work

  1. Our instance sends a Follow activity to the relay actor
  2. The relay sends back an Accept activity
  3. When any subscribed instance publishes public content, the relay
     sends an Announce activity to all followers
  4. We receive and process the Announced content like any other federated post

  ## Common Relays

  - `https://relay.fedi.buzz/actor` - ActivityRelay (general purpose)
  - `https://relay.infosec.exchange/actor` - Infosec community relay
  """

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Fetcher, HTTPSignature, Publisher, RelaySubscription}
  alias Elektrine.Repo

  import Ecto.Query

  require Logger

  @relay_actor_nickname "relay"

  @doc """
  Returns the AP ID of this instance's relay actor.
  """
  def relay_actor_id do
    "#{ActivityPub.instance_url()}/#{@relay_actor_nickname}"
  end

  @doc """
  Gets or creates the local relay actor.
  The relay actor is an Application-type actor that represents this instance
  for relay federation purposes.
  """
  def get_or_create_relay_actor do
    # Check if we already have a relay actor
    case Repo.get_by(ActivityPub.Actor, uri: relay_actor_id()) do
      nil ->
        create_relay_actor()

      actor ->
        {:ok, actor}
    end
  end

  defp create_relay_actor do
    # Generate a key pair for the relay actor
    {public_key, private_key} = generate_key_pair()

    actor_attrs = %{
      uri: relay_actor_id(),
      username: @relay_actor_nickname,
      domain: ActivityPub.instance_domain(),
      inbox_url: "#{ActivityPub.instance_url()}/#{@relay_actor_nickname}/inbox",
      outbox_url: "#{ActivityPub.instance_url()}/#{@relay_actor_nickname}/outbox",
      followers_url: "#{ActivityPub.instance_url()}/#{@relay_actor_nickname}/followers",
      following_url: "#{ActivityPub.instance_url()}/#{@relay_actor_nickname}/following",
      public_key: public_key,
      actor_type: "Application",
      display_name: "Elektrine Relay",
      summary: "Relay actor for #{ActivityPub.instance_domain()}",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      # Store private key in metadata since actors table doesn't have private_key column
      # This is used for signing outgoing activities to relays
      metadata: %{"private_key" => private_key}
    }

    %ActivityPub.Actor{}
    |> ActivityPub.Actor.changeset(actor_attrs)
    |> Repo.insert()
  end

  defp generate_key_pair do
    HTTPSignature.generate_key_pair()
  end

  @doc """
  Subscribes to a relay by sending a Follow activity.

  ## Parameters

  - `relay_uri` - The relay actor URI (e.g., "https://relay.fedi.buzz/actor")
  - `admin_user_id` - The admin user initiating the subscription
  """
  def subscribe(relay_uri, admin_user_id \\ nil) do
    with {:ok, relay_actor} <- get_or_create_relay_actor(),
         {:ok, remote_relay} <- fetch_relay_actor(relay_uri),
         {:ok, subscription} <- create_subscription(relay_uri, remote_relay, admin_user_id),
         {:ok, activity} <- send_follow(relay_actor, remote_relay, subscription) do
      # Update subscription with the follow activity ID
      subscription
      |> RelaySubscription.changeset(%{follow_activity_id: activity["id"]})
      |> Repo.update()

      Logger.info("Relay: Sent follow to #{relay_uri}")
      {:ok, subscription}
    else
      {:error, :already_subscribed} ->
        {:error, "Already subscribed to this relay"}

      {:error, reason} ->
        Logger.error("Relay: Failed to subscribe to #{relay_uri}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Unsubscribes from a relay by sending an Undo Follow activity.
  """
  def unsubscribe(relay_uri) do
    with {:ok, subscription} <- get_subscription(relay_uri),
         {:ok, relay_actor} <- get_or_create_relay_actor(),
         {:ok, remote_relay} <- fetch_relay_actor(relay_uri),
         :ok <- send_unfollow(relay_actor, remote_relay, subscription) do
      # Delete the subscription
      Repo.delete(subscription)
      Logger.info("Relay: Unfollowed #{relay_uri}")
      {:ok, :unfollowed}
    else
      {:error, :not_found} ->
        {:error, "Not subscribed to this relay"}

      {:error, reason} ->
        Logger.error("Relay: Failed to unsubscribe from #{relay_uri}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Force deletes a relay subscription without sending an Unfollow activity.
  Use when the remote relay is unreachable or for cleanup.
  """
  def force_delete(relay_uri) do
    case get_subscription(relay_uri) do
      {:ok, subscription} ->
        Repo.delete(subscription)
        Logger.info("Relay: Force deleted subscription to #{relay_uri}")
        {:ok, :deleted}

      {:error, :not_found} ->
        {:error, "Not subscribed to this relay"}
    end
  end

  @doc """
  Lists all relay subscriptions.
  """
  def list_subscriptions do
    from(s in RelaySubscription,
      order_by: [desc: s.inserted_at],
      preload: [:subscribed_by]
    )
    |> Repo.all()
  end

  @doc """
  Gets active relay subscriptions.
  """
  def list_active_subscriptions do
    from(s in RelaySubscription,
      where: s.status == "active" and s.accepted == true
    )
    |> Repo.all()
  end

  @doc """
  Gets pending relay subscriptions (stuck waiting for Accept).
  """
  def list_pending_subscriptions do
    from(s in RelaySubscription,
      where: s.status == "pending",
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Force activates all pending subscriptions.
  Use this for relays that auto-accept but don't send Accept activities.
  """
  def force_activate_all_pending do
    pending = list_pending_subscriptions()

    results =
      Enum.map(pending, fn sub ->
        case force_activate(sub.relay_uri) do
          {:ok, _} -> {:ok, sub.relay_uri}
          {:error, reason} -> {:error, sub.relay_uri, reason}
        end
      end)

    activated = Enum.count(results, fn r -> match?({:ok, _}, r) end)
    Logger.info("Relay: Force activated #{activated}/#{length(pending)} pending subscriptions")
    {:ok, results}
  end

  @doc """
  Gets a subscription by relay URI.
  """
  def get_subscription(relay_uri) do
    case Repo.get_by(RelaySubscription, relay_uri: relay_uri) do
      nil -> {:error, :not_found}
      subscription -> {:ok, subscription}
    end
  end

  @doc """
  Handles an Accept activity for a relay follow.
  Called by the ActivityPub handler when we receive an Accept.

  Supports multiple formats:
  - Exact follow_activity_id match
  - Match by relay_uri when relay sends Accept with actor URI as object
  """
  def handle_accept(follow_activity_id) do
    Logger.debug("Relay: Looking for subscription with follow_activity_id: #{follow_activity_id}")

    # First try exact match on follow_activity_id
    case Repo.get_by(RelaySubscription, follow_activity_id: follow_activity_id) do
      nil ->
        # Try matching by relay_uri (some relays send Accept with actor URI as object)
        case Repo.get_by(RelaySubscription, relay_uri: follow_activity_id) do
          nil ->
            Logger.debug("Relay: No subscription found for #{follow_activity_id}")
            {:error, :subscription_not_found}

          subscription ->
            activate_subscription(subscription)
        end

      subscription ->
        activate_subscription(subscription)
    end
  end

  @doc """
  Handles an Accept activity by actor URI.
  Called when we receive an Accept from a specific actor.
  """
  def handle_accept_from_actor(actor_uri) do
    Logger.debug("Relay: Looking for subscription from actor: #{actor_uri}")

    # Find pending subscription for this relay actor
    case Repo.get_by(RelaySubscription, relay_uri: actor_uri, status: "pending") do
      nil ->
        Logger.debug("Relay: No pending subscription found for actor #{actor_uri}")
        {:error, :subscription_not_found}

      subscription ->
        activate_subscription(subscription)
    end
  end

  defp activate_subscription(subscription) do
    case subscription
         |> RelaySubscription.changeset(%{status: "active", accepted: true})
         |> Repo.update() do
      {:ok, updated_subscription} ->
        Logger.info("Relay: Subscription to #{subscription.relay_uri} accepted")
        {:ok, updated_subscription}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Manually activates a pending relay subscription.
  Use this for relays that don't send Accept activities or when debugging.
  """
  def force_activate(relay_uri) do
    case get_subscription(relay_uri) do
      {:ok, subscription} ->
        activate_subscription(subscription)

      {:error, :not_found} ->
        {:error, :subscription_not_found}
    end
  end

  @doc """
  Retries sending Follow to a relay that's stuck in pending.
  """
  def retry_subscription(relay_uri) do
    with {:ok, subscription} <- get_subscription(relay_uri),
         {:ok, relay_actor} <- get_or_create_relay_actor(),
         {:ok, remote_relay} <- fetch_relay_actor(relay_uri) do
      # Reset status to pending and retry
      subscription
      |> RelaySubscription.changeset(%{status: "pending", error_message: nil})
      |> Repo.update!()

      case send_follow(relay_actor, remote_relay, subscription) do
        {:ok, activity} ->
          # Update with new activity ID
          subscription
          |> RelaySubscription.changeset(%{follow_activity_id: activity["id"]})
          |> Repo.update()

          Logger.info("Relay: Retried follow to #{relay_uri}")
          {:ok, :retried}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Debug function to show subscription details.
  """
  def debug_subscription(relay_uri) do
    case get_subscription(relay_uri) do
      {:ok, subscription} ->
        {:ok,
         %{
           relay_uri: subscription.relay_uri,
           follow_activity_id: subscription.follow_activity_id,
           status: subscription.status,
           accepted: subscription.accepted,
           error_message: subscription.error_message,
           inserted_at: subscription.inserted_at,
           updated_at: subscription.updated_at
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Handles a Reject activity for a relay follow.
  """
  def handle_reject(follow_activity_id) do
    case Repo.get_by(RelaySubscription, follow_activity_id: follow_activity_id) do
      nil ->
        {:error, :subscription_not_found}

      subscription ->
        case subscription
             |> RelaySubscription.changeset(%{status: "rejected", accepted: false})
             |> Repo.update() do
          {:ok, updated_subscription} ->
            Logger.info("Relay: Subscription to #{subscription.relay_uri} rejected")
            {:ok, updated_subscription}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Publishes a local public post to all active relay subscriptions.
  This sends an Announce activity to each relay's inbox.
  """
  def publish_to_relays(activity) do
    # Only publish Create activities for public content
    if should_publish_to_relays?(activity) do
      relays = list_active_subscriptions()

      if relays != [] do
        Task.start(fn ->
          Enum.each(relays, fn subscription ->
            publish_to_relay(activity, subscription)
          end)
        end)
      end
    end

    :ok
  end

  defp should_publish_to_relays?(%{"type" => "Create", "object" => object}) when is_map(object) do
    # Only public posts
    to = object["to"] || []
    "https://www.w3.org/ns/activitystreams#Public" in to
  end

  defp should_publish_to_relays?(_), do: false

  defp publish_to_relay(activity, subscription) do
    with {:ok, relay_actor} <- get_or_create_relay_actor() do
      # Build an Announce activity
      announce = build_announce(relay_actor, activity)

      # Send to the relay's inbox
      case Publisher.deliver(announce, relay_actor, subscription.relay_inbox) do
        {:ok, :delivered} ->
          Logger.debug("Relay: Published to #{subscription.relay_uri}")

        {:error, reason} ->
          Logger.warning(
            "Relay: Failed to publish to #{subscription.relay_uri}: #{inspect(reason)}"
          )
      end
    end
  end

  defp build_announce(relay_actor, activity) do
    object_id = activity["object"]["id"] || activity["object"]

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{ActivityPub.instance_url()}/activities/#{Ecto.UUID.generate()}",
      "type" => "Announce",
      "actor" => relay_actor.uri,
      "object" => object_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [relay_actor.followers_url]
    }
  end

  # Private functions

  defp fetch_relay_actor(relay_uri) do
    case Fetcher.fetch_object(relay_uri) do
      {:ok, actor_data} ->
        {:ok,
         %{
           uri: actor_data["id"],
           inbox: actor_data["inbox"] || actor_data["endpoints"]["sharedInbox"],
           name: actor_data["name"] || actor_data["preferredUsername"],
           software: detect_relay_software(actor_data)
         }}

      {:error, reason} ->
        {:error, {:fetch_failed, reason}}
    end
  end

  defp detect_relay_software(actor_data) do
    cond do
      String.contains?(actor_data["name"] || "", "ActivityRelay") -> "ActivityRelay"
      String.contains?(actor_data["summary"] || "", "ActivityRelay") -> "ActivityRelay"
      actor_data["type"] == "Application" -> "Generic Relay"
      true -> "Unknown"
    end
  end

  defp create_subscription(relay_uri, remote_relay, admin_user_id) do
    # Check if already subscribed
    case Repo.get_by(RelaySubscription, relay_uri: relay_uri) do
      nil ->
        %RelaySubscription{}
        |> RelaySubscription.changeset(%{
          relay_uri: relay_uri,
          relay_inbox: remote_relay.inbox,
          relay_name: remote_relay.name,
          relay_software: remote_relay.software,
          status: "pending",
          subscribed_by_id: admin_user_id
        })
        |> Repo.insert()

      _existing ->
        {:error, :already_subscribed}
    end
  end

  defp send_follow(relay_actor, remote_relay, subscription) do
    # Use dynamic URL for the relay actor to match what we serve at /relay
    relay_url = relay_actor_id()

    follow_activity = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{ActivityPub.instance_url()}/activities/#{Ecto.UUID.generate()}",
      "type" => "Follow",
      "actor" => relay_url,
      "object" => remote_relay.uri
    }

    # Store the activity
    ActivityPub.create_activity(%{
      activity_id: follow_activity["id"],
      activity_type: "Follow",
      actor_uri: relay_url,
      object_id: remote_relay.uri,
      data: follow_activity,
      local: true,
      processed: true
    })

    # Deliver to the relay
    case Publisher.deliver(follow_activity, relay_actor, remote_relay.inbox) do
      {:ok, :delivered} ->
        {:ok, follow_activity}

      {:error, reason} ->
        # Mark subscription as error
        subscription
        |> RelaySubscription.changeset(%{
          status: "error",
          error_message: "Delivery failed: #{inspect(reason)}"
        })
        |> Repo.update()

        {:error, {:delivery_failed, reason}}
    end
  end

  defp send_unfollow(relay_actor, remote_relay, subscription) do
    # Use dynamic URL for the relay actor to match what we serve at /relay
    relay_url = relay_actor_id()

    # Build Undo Follow
    undo_activity = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{ActivityPub.instance_url()}/activities/#{Ecto.UUID.generate()}",
      "type" => "Undo",
      "actor" => relay_url,
      "object" => %{
        "id" => subscription.follow_activity_id,
        "type" => "Follow",
        "actor" => relay_url,
        "object" => remote_relay.uri
      }
    }

    # Deliver to the relay
    case Publisher.deliver(undo_activity, relay_actor, remote_relay.inbox) do
      {:ok, :delivered} -> :ok
      {:error, reason} -> {:error, {:delivery_failed, reason}}
    end
  end
end
