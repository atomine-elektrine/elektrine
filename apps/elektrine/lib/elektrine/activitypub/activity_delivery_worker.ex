defmodule Elektrine.ActivityPub.ActivityDeliveryWorker do
  @moduledoc """
  Oban worker for delivering ActivityPub activities to remote instances.

  Replaces the old DeliveryWorker GenServer with guaranteed delivery
  and automatic retries.

  Uses Lemmy-style per-domain throttling to prevent overwhelming
  remote instances with too many concurrent requests.
  """

  use Oban.Worker,
    queue: :activitypub_delivery,
    max_attempts: 1,
    unique: [period: 300, fields: [:args], keys: [:delivery_id]]

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.DomainThrottler
  alias Elektrine.ActivityPub.Publisher
  alias Elektrine.Telemetry.Events

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}}) do
    started_at = System.monotonic_time(:millisecond)

    case ActivityPub.get_delivery(delivery_id) do
      nil ->
        Logger.warning("ActivityDeliveryWorker: Delivery #{delivery_id} not found")

        Events.federation(:delivery_worker, :perform, :missing_delivery, nil, %{
          delivery_id: delivery_id
        })

        :ok

      %{status: status} when status != "pending" ->
        Logger.debug(
          "ActivityDeliveryWorker: Delivery #{delivery_id} already processed (#{status})"
        )

        Events.federation(:delivery_worker, :perform, :already_processed, nil, %{
          delivery_id: delivery_id,
          status: status
        })

        :ok

      delivery ->
        # Extract domain from inbox URL for throttling
        domain = inbox_domain(delivery.inbox_url)

        # Try to acquire a processing slot for this domain (Lemmy-style)
        case DomainThrottler.acquire(domain) do
          {:ok, :acquired} ->
            result = process_delivery(delivery)

            # Release slot with success/failure status
            success? =
              case result do
                {:ok, _} -> true
                _ -> false
              end

            DomainThrottler.release(domain, success?)

            outcome =
              case result do
                {:ok, _} -> :success
                _ -> :failure
              end

            Events.federation(
              :delivery_worker,
              :perform,
              outcome,
              System.monotonic_time(:millisecond) - started_at,
              %{
                delivery_id: delivery_id,
                actor_domain: domain
              }
            )

            # Delivery retries are driven by next_retry_at + DeliveryRetryWorker.
            # This job should complete after one attempt.
            :ok

          {:error, :throttled} ->
            # Domain has too many concurrent deliveries, snooze and retry
            Logger.debug("Throttled delivery to #{domain}, snoozing for 5s")

            Events.federation(
              :delivery_worker,
              :perform,
              :throttled,
              System.monotonic_time(:millisecond) - started_at,
              %{
                delivery_id: delivery_id,
                actor_domain: domain
              }
            )

            {:snooze, 5}

          {:error, :backoff, remaining_ms} ->
            # Domain is in backoff due to failures
            snooze_seconds = max(1, div(remaining_ms, 1000))
            Logger.info("Domain #{domain} in backoff, snoozing delivery for #{snooze_seconds}s")

            Events.federation(
              :delivery_worker,
              :perform,
              :backoff,
              System.monotonic_time(:millisecond) - started_at,
              %{
                delivery_id: delivery_id,
                actor_domain: domain,
                backoff_ms: remaining_ms
              }
            )

            {:snooze, snooze_seconds}
        end
    end
  end

  defp process_delivery(delivery) do
    started_at = System.monotonic_time(:millisecond)
    activity = delivery.activity
    domain = inbox_domain(delivery.inbox_url)

    case get_signing_entity(activity) do
      {:ok, entity} ->
        # Attempt delivery
        case Publisher.deliver(activity.data, entity, delivery.inbox_url) do
          {:ok, :delivered} ->
            ActivityPub.mark_delivery_delivered(delivery.id)
            Logger.info("ActivityDeliveryWorker: Delivered to #{delivery.inbox_url}")

            Events.federation(
              :delivery_worker,
              :deliver,
              :success,
              System.monotonic_time(:millisecond) - started_at,
              %{
                delivery_id: delivery.id,
                actor_domain: domain
              }
            )

            {:ok, :delivered}

          {:error, reason} ->
            ActivityPub.mark_delivery_failed(delivery.id, reason)

            Logger.warning(
              "ActivityDeliveryWorker: Failed to deliver to #{delivery.inbox_url}: #{inspect(reason)}"
            )

            Events.federation(
              :delivery_worker,
              :deliver,
              :failure,
              System.monotonic_time(:millisecond) - started_at,
              %{
                delivery_id: delivery.id,
                actor_domain: domain,
                reason: inspect(reason)
              }
            )

            {:error, reason}
        end

      {:error, reason} ->
        ActivityPub.mark_delivery_failed(delivery.id, reason)
        Logger.warning("ActivityDeliveryWorker: #{reason} for delivery #{delivery.id}")

        Events.federation(
          :delivery_worker,
          :deliver,
          :failure,
          System.monotonic_time(:millisecond) - started_at,
          %{
            delivery_id: delivery.id,
            actor_domain: domain,
            reason: inspect(reason)
          }
        )

        {:error, reason}
    end
  rescue
    e ->
      Logger.error(
        "ActivityDeliveryWorker: Error processing delivery #{delivery.id}: #{inspect(e)}"
      )

      ActivityPub.mark_delivery_failed(delivery.id, inspect(e))

      Events.federation(:delivery_worker, :deliver, :failure, nil, %{
        delivery_id: delivery.id,
        actor_domain: inbox_domain(delivery.inbox_url),
        reason: inspect(e)
      })

      {:error, inspect(e)}
  end

  defp get_signing_entity(activity) do
    cond do
      is_integer(activity.internal_user_id) ->
        case Elektrine.Repo.get(Elektrine.Accounts.User, activity.internal_user_id) do
          nil ->
            {:error, "User not found"}

          user ->
            {:ok, user}
        end

      is_binary(activity.actor_uri) ->
        case ActivityPub.get_actor_by_uri(activity.actor_uri) do
          %ActivityPub.Actor{} = actor ->
            if actor.domain == ActivityPub.instance_domain() do
              {:ok, actor}
            else
              {:error, "Local actor not found"}
            end

          _ ->
            {:error, "Local actor not found"}
        end

      true ->
        {:error, "No signing entity found"}
    end
  end

  @doc """
  Enqueue a delivery for processing.
  """
  def enqueue(delivery_id) do
    %{delivery_id: delivery_id}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Enqueue multiple deliveries for processing.
  """
  def enqueue_many(delivery_ids) when is_list(delivery_ids) do
    jobs =
      Enum.map(delivery_ids, fn id ->
        new(%{delivery_id: id})
      end)

    Oban.insert_all(jobs)
  end

  defp inbox_domain(inbox_url) when is_binary(inbox_url) do
    case URI.parse(inbox_url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "unknown"
    end
  end

  defp inbox_domain(_), do: "unknown"
end
