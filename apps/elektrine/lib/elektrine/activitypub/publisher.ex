defmodule Elektrine.ActivityPub.Publisher do
  @moduledoc """
  Publishes ActivityPub activities to remote instances.
  """

  require Logger
  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.HTTPSignature
  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.Security.URLValidator

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
             actor_uri: ActivityPub.actor_uri(user),
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
  def deliver(activity, entity, inbox_url, opts \\ []) do
    with :ok <- validate_inbox_url(inbox_url),
         {:ok, entity} <- Elektrine.ActivityPub.KeyManager.ensure_user_has_keys(entity) do
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
      {private_key, key_id} = get_signing_info(entity, opts)
      signature_headers = HTTPSignature.sign(inbox_url, body, private_key, key_id)

      all_headers = base_headers ++ signature_headers

      # Build and send the request
      request = Finch.build(:post, inbox_url, all_headers, body)

      case SafeFetch.request(request, Elektrine.Finch, receive_timeout: 10_000) do
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

    follows
    |> Enum.map(&Map.get(actors_map, &1.remote_actor_id))
    |> Enum.reject(&is_nil/1)
    |> optimize_inboxes()
  end

  # Optimizes inbox delivery by using shared inboxes when possible.
  # When sending to multiple users on the same instance, use their shared inbox.
  defp optimize_inboxes(actors) do
    actors
    |> Enum.group_by(& &1.domain)
    |> Enum.flat_map(fn {_domain, domain_actors} ->
      case shared_inbox_for_group(domain_actors) do
        {:ok, shared_inbox} ->
          [shared_inbox]

        :error ->
          domain_actors
          |> Enum.map(& &1.inbox_url)
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.uniq()
      end
    end)
  end

  defp shared_inbox_for_group(domain_actors) do
    shared_inboxes =
      domain_actors
      |> Enum.map(&shared_inbox_for_actor/1)

    unique_shared_inboxes = shared_inboxes |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if length(domain_actors) > 1 and
         match?([_], unique_shared_inboxes) and
         Enum.all?(shared_inboxes, &(&1 == hd(unique_shared_inboxes))) do
      {:ok, hd(unique_shared_inboxes)}
    else
      :error
    end
  end

  defp shared_inbox_for_actor(%ActivityPub.Actor{} = actor) do
    case get_in(actor.metadata || %{}, ["endpoints", "sharedInbox"]) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp shared_inbox_for_actor(_), do: nil

  # Extracts signing key and key_id based on entity type (User or Actor)
  defp get_signing_info(%User{} = user, opts) do
    key_id_base =
      case Keyword.get(opts, :key_id_base_url) do
        value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
        _ -> ActivityPub.instance_url()
      end

    key_id = ActivityPub.actor_key_id(user, key_id_base)
    {user.activitypub_private_key, key_id}
  end

  defp get_signing_info(%ActivityPub.Actor{username: "relay"} = actor, _opts) do
    # For relay actor, use dynamic URL to match current instance domain
    private_key = ActivityPub.Actor.metadata_private_key(actor)
    key_id = "#{ActivityPub.instance_url()}/relay#main-key"
    {private_key, key_id}
  end

  defp get_signing_info(%ActivityPub.Actor{} = actor, _opts) do
    private_key = ActivityPub.Actor.metadata_private_key(actor)
    key_id = "#{actor.uri}#main-key"
    {private_key, key_id}
  end

  defp validate_inbox_url(inbox_url) when is_binary(inbox_url) do
    case URLValidator.validate(inbox_url) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Blocked unsafe ActivityPub inbox URL #{inspect(inbox_url)}: #{inspect(reason)}"
        )

        {:error, :unsafe_inbox_url}
    end
  end

  defp validate_inbox_url(_), do: {:error, :unsafe_inbox_url}

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
