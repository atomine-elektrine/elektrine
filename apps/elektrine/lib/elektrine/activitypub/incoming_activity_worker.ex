defmodule Elektrine.ActivityPub.IncomingActivityWorker do
  @moduledoc """
  Background worker for processing incoming ActivityPub activities.

  Activities are saved to the database immediately when received, then this
  worker processes them asynchronously to avoid blocking the inbox endpoint.

  Benefits:
  - Inbox endpoint returns immediately (202 Accepted)
  - Remote HTTP calls don't block web requests
  - Failed activities can be retried
  - Backpressure handling via batch size limits
  """

  use GenServer
  require Logger

  alias Elektrine.Repo
  alias Elektrine.ActivityPub.Activity
  alias Elektrine.ActivityPub.Handler
  import Ecto.Query

  # Process activities every 30 seconds
  @tick_interval 30_000
  # Process up to 10 activities per tick
  @batch_size 10
  # Max retry attempts before giving up
  @max_attempts 2

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers immediate processing (useful after receiving new activities).
  """
  def process_now do
    GenServer.cast(__MODULE__, :process_now)
  end

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{processing: false}}
  end

  @impl true
  def handle_info(:tick, state) do
    state =
      if !state.processing do
        try do
          process_pending_activities()
        rescue
          e ->
            Logger.error("IncomingActivityWorker error: #{Exception.message(e)}")
        end

        state
      else
        state
      end

    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:process_now, state) do
    if !state.processing do
      try do
        process_pending_activities()
      rescue
        e ->
          Logger.error("IncomingActivityWorker error: #{Exception.message(e)}")
      end
    end

    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval)
  end

  defp process_pending_activities do
    # Get unprocessed incoming activities (local = false)
    activities =
      from(a in Activity,
        where: a.processed == false and a.local == false and a.process_attempts < @max_attempts,
        order_by: [asc: a.inserted_at],
        limit: ^@batch_size
      )
      |> Repo.all()

    # Process each activity
    Enum.each(activities, fn activity ->
      process_activity(activity)
      # Small delay between activities to avoid overwhelming resources
      Process.sleep(50)
    end)
  end

  defp process_activity(activity) do
    # Pre-filter: Skip activities with unfetchable Lemmy /activities/ URLs
    object_uri = get_in(activity.data, ["object"])

    if is_binary(object_uri) && String.contains?(object_uri, "/activities/") do
      # Mark as processed immediately - these URLs are never fetchable
      activity
      |> Activity.mark_processed_changeset(%{
        processed: true,
        processed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        process_error: "Skipped: Lemmy activity URL not fetchable"
      })
      |> Repo.update()
    else
      do_process_activity(activity)
    end
  end

  defp do_process_activity(activity) do
    # Increment attempt counter first
    activity
    |> Activity.mark_processed_changeset(%{process_attempts: activity.process_attempts + 1})
    |> Repo.update()

    # Get the target user if this activity was directed at someone
    target_user = get_target_user(activity)

    # Process the activity using the handler
    result =
      try do
        Handler.process_activity_async(activity.data, activity.actor_uri, target_user)
      rescue
        e ->
          Logger.error(
            "Error processing activity #{activity.activity_id}: #{Exception.message(e)}"
          )

          {:error, Exception.message(e)}
      catch
        :exit, reason ->
          Logger.error("Activity processing exited: #{inspect(reason)}")
          {:error, "Process exited: #{inspect(reason)}"}
      end

    # Update activity with result
    case result do
      {:ok, _} ->
        activity
        |> Activity.mark_processed_changeset(%{
          processed: true,
          processed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          process_error: nil
        })
        |> Repo.update()

      {:error, reason} ->
        error_msg = if is_binary(reason), do: reason, else: inspect(reason)

        activity
        |> Activity.mark_processed_changeset(%{
          process_error: String.slice(error_msg, 0, 255)
        })
        |> Repo.update()

        if activity.process_attempts >= @max_attempts do
          Logger.warning(
            "Activity #{activity.activity_id} failed after #{@max_attempts} attempts: #{error_msg}"
          )
        end
    end
  end

  # Try to determine the target user for this activity
  defp get_target_user(activity) do
    # Check if the activity's object points to a local user
    case activity.object_id do
      nil ->
        nil

      object_id ->
        # If object_id looks like a local user URI, try to find them
        if String.contains?(object_id, "/users/") do
          # Extract username from URI like https://example.com/users/username
          case Regex.run(~r{/users/([^/]+)/?}, object_id) do
            [_, username] ->
              Elektrine.Accounts.get_user_by_username(username)

            _ ->
              nil
          end
        else
          nil
        end
    end
  end
end
