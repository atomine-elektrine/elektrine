defmodule Elektrine.ActivityPub.Publisher do
  @moduledoc """
  Publishes ActivityPub activities to remote instances.
  """

  require Logger
  import Ecto.Query

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.HTTPSignature
  alias Elektrine.Accounts.User

  @doc """
  Publishes an activity to remote inboxes.
  Creates delivery records and queues them for processing.
  Supports both user activities and community actor activities (when user is nil).
  """
  def publish(activity, nil, inbox_urls) when is_list(inbox_urls) do
    # Community actor publishing (no user associated)
    # Extract the actor URI from the activity itself
    actor_uri = activity["actor"]

    # Save the activity first (handle duplicates)
    activity_record =
      case ActivityPub.create_activity(%{
             activity_id: activity["id"],
             activity_type: activity["type"],
             actor_uri: actor_uri,
             object_id: get_object_id(activity),
             data: activity,
             local: true,
             # No user for community actors
             internal_user_id: nil
           }) do
        {:ok, record} ->
          record

        {:error, %Ecto.Changeset{errors: [activity_id: {"has already been taken", _}]}} ->
          # Already exists, get it
          ActivityPub.get_activity_by_id(activity["id"])

        {:error, changeset} ->
          raise "Failed to create activity: #{inspect(changeset)}"
      end

    # Create delivery records
    unique_inboxes = Enum.uniq(inbox_urls)
    ActivityPub.create_deliveries(activity_record.id, unique_inboxes)

    # Trigger delivery worker
    schedule_deliveries()

    {:ok, activity_record}
  end

  def publish(activity, %User{} = user, inbox_urls) when is_list(inbox_urls) do
    # Save the activity first (handle duplicates)
    activity_record =
      case ActivityPub.create_activity(%{
             activity_id: activity["id"],
             activity_type: activity["type"],
             actor_uri: "#{ActivityPub.instance_url()}/users/#{user.username}",
             object_id: get_object_id(activity),
             data: activity,
             local: true,
             internal_user_id: user.id
           }) do
        {:ok, record} ->
          record

        {:error, %Ecto.Changeset{errors: [activity_id: {"has already been taken", _}]}} ->
          # Already exists, get it
          ActivityPub.get_activity_by_id(activity["id"])

        {:error, changeset} ->
          raise "Failed to create activity: #{inspect(changeset)}"
      end

    # Create delivery records
    unique_inboxes = Enum.uniq(inbox_urls)
    ActivityPub.create_deliveries(activity_record.id, unique_inboxes)

    # Trigger delivery worker
    schedule_deliveries()

    {:ok, activity_record}
  end

  defp get_object_id(%{"object" => object}) when is_binary(object), do: object
  defp get_object_id(%{"object" => %{"id" => id}}), do: id
  defp get_object_id(_), do: nil

  @doc """
  Delivers an activity to a specific inbox.
  Signs the request with HTTP Signatures.

  Accepts either a User or Actor struct for signing.
  """
  def deliver(activity, entity, inbox_url) do
    # Ensure entity has keys before signing
    {:ok, entity} = Elektrine.ActivityPub.KeyManager.ensure_user_has_keys(entity)
    body = Jason.encode!(activity)

    # Log the activity being sent for debugging
    if String.contains?(inbox_url, "relay") do
      Logger.debug(
        "Sending activity to relay: #{inspect(activity, pretty: true, limit: :infinity)}"
      )
    end

    base_headers = [
      {"content-type", "application/activity+json"},
      {"accept", "application/activity+json"},
      {"user-agent", "Elektrine/1.0"}
    ]

    # Sign the request - extract key info based on entity type
    {private_key, key_id} = get_signing_info(entity)
    signature_headers = HTTPSignature.sign(inbox_url, body, private_key, key_id)

    all_headers = base_headers ++ signature_headers

    # Build and send the request
    request = Finch.build(:post, inbox_url, all_headers, body)

    case Finch.request(request, Elektrine.Finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        Logger.info("Successfully delivered to #{inbox_url}")
        {:ok, :delivered}

      {:ok, %Finch.Response{status: status, body: error_body}} ->
        Logger.warning(
          "Failed to deliver to #{inbox_url}, status: #{status}, body: #{inspect(error_body)}"
        )

        Logger.debug("Failed delivery - Activity: #{inspect(activity, limit: :infinity)}")
        Logger.debug("Failed delivery - Headers: #{inspect(all_headers)}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.error("HTTP error delivering to #{inbox_url}: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  @doc """
  Gets the inbox URLs for all followers of a user.
  """
  def get_follower_inboxes(user_id) do
    # Get remote followers
    follows = Elektrine.Profiles.list_remote_followers(user_id)

    # Batch fetch all actors in a single query instead of N+1
    actor_ids = Enum.map(follows, & &1.remote_actor_id) |> Enum.filter(& &1)

    actors_map =
      if Enum.empty?(actor_ids) do
        %{}
      else
        Elektrine.ActivityPub.Actor
        |> where([a], a.id in ^actor_ids)
        |> Elektrine.Repo.all()
        |> Map.new(fn actor -> {actor.id, actor} end)
      end

    # Map follows to inbox URLs using the pre-fetched actors
    follows
    |> Enum.map(fn follow ->
      case Map.get(actors_map, follow.remote_actor_id) do
        nil -> nil
        actor -> actor.inbox_url
      end
    end)
    |> Enum.filter(&(&1 != nil))
    |> optimize_inboxes()
  end

  # Optimizes inbox delivery by using shared inboxes when possible.
  # When sending to multiple users on the same instance, use their shared inbox.
  defp optimize_inboxes(inbox_urls) do
    # Group inboxes by domain
    grouped =
      Enum.group_by(inbox_urls, fn url ->
        %URI{host: host} = URI.parse(url)
        host
      end)

    # For each domain, check if we should use shared inbox
    Enum.flat_map(grouped, fn {domain, urls} ->
      if length(urls) > 1 do
        # Multiple recipients on same domain - use shared inbox
        {:ok, shared_inbox} = get_shared_inbox_for_domain(domain, List.first(urls))
        [shared_inbox]
      else
        # Only one recipient on this domain, use individual inbox
        urls
      end
    end)
  end

  defp get_shared_inbox_for_domain(domain, _sample_inbox_url) do
    # Try to extract shared inbox from the actor
    # Most instances have sharedInbox at https://domain/inbox
    shared_inbox_url = "https://#{domain}/inbox"

    # Verify this is actually a shared inbox by checking if any actor on this domain advertises it
    actor =
      Elektrine.ActivityPub.Actor
      |> where([a], a.domain == ^domain)
      |> limit(1)
      |> Elektrine.Repo.one()

    if actor && actor.metadata do
      # Check if actor's metadata has sharedInbox endpoint
      shared_inbox = get_in(actor.metadata, ["endpoints", "sharedInbox"])

      if shared_inbox do
        {:ok, shared_inbox}
      else
        # Fallback to standard pattern
        {:ok, shared_inbox_url}
      end
    else
      # No actor cached yet, use standard pattern
      {:ok, shared_inbox_url}
    end
  end

  # Extracts signing key and key_id based on entity type (User or Actor)
  defp get_signing_info(%User{} = user) do
    key_id = "#{ActivityPub.instance_url()}/users/#{user.username}#main-key"
    {user.activitypub_private_key, key_id}
  end

  defp get_signing_info(%ActivityPub.Actor{username: "relay"} = actor) do
    # For relay actor, use dynamic URL to match current instance domain
    private_key = get_in(actor.metadata, ["private_key"])
    key_id = "#{ActivityPub.instance_url()}/relay#main-key"
    {private_key, key_id}
  end

  defp get_signing_info(%ActivityPub.Actor{} = actor) do
    private_key = get_in(actor.metadata, ["private_key"])
    key_id = "#{actor.uri}#main-key"
    {private_key, key_id}
  end

  # Schedule delivery processing
  defp schedule_deliveries do
    # Trigger the delivery worker
    # This will be handled by the DeliveryWorker
    Process.send_after(self(), :process_deliveries, 100)
  end

  @doc """
  Asynchronously publishes an activity via Oban job queue.
  Used by the Pipeline for outgoing local activities.
  Creates delivery records and queues them via ActivityDeliveryWorker.
  """
  def publish_async(activity, user) do
    # Get inbox URLs for followers
    inbox_urls = get_follower_inboxes(user.id)

    if Enum.empty?(inbox_urls) do
      Logger.debug("No followers to deliver activity to")
      :ok
    else
      # Use the existing publish/3 flow which creates deliveries and schedules them
      # publish/3 raises on failure, so wrap in try/rescue
      {:ok, _activity_record} = publish(activity, user, inbox_urls)
      :ok
    end
  rescue
    e ->
      Logger.warning("Failed to queue federation publish: #{inspect(e)}")
      {:error, :queue_failed}
  end
end
