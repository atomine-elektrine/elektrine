defmodule Elektrine.ActivityPub.IncomingActivityWorker do
  @moduledoc "Background worker for processing incoming ActivityPub activities.\n\nActivities are saved to the database immediately when received, then this\nworker processes them asynchronously to avoid blocking the inbox endpoint.\n\nBenefits:\n- Inbox endpoint returns immediately (202 Accepted)\n- Remote HTTP calls don't block web requests\n- Failed activities can be retried\n- Backpressure handling via batch size limits\n"
  use GenServer
  require Logger
  alias Elektrine.ActivityPub.Activity
  alias Elektrine.ActivityPub.Handler
  alias Elektrine.Repo
  import Ecto.Query
  @tick_interval 30_000
  @batch_size 10
  @max_attempts 2
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Triggers immediate processing (useful after receiving new activities).\n"
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
      if state.processing do
        state
      else
        try do
          process_pending_activities()
        rescue
          e -> Logger.error("IncomingActivityWorker error: #{Exception.message(e)}")
        end

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
        e -> Logger.error("IncomingActivityWorker error: #{Exception.message(e)}")
      end
    end

    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval)
  end

  defp process_pending_activities do
    activities =
      from(a in Activity,
        where: a.processed == false and a.local == false and a.process_attempts < @max_attempts,
        order_by: [asc: a.inserted_at],
        limit: ^@batch_size
      )
      |> Repo.all()

    Enum.each(activities, fn activity ->
      process_activity(activity)
      Process.sleep(50)
    end)
  end

  defp process_activity(activity) do
    object_uri = get_in(activity.data, ["object"])

    if is_binary(object_uri) && String.contains?(object_uri, "/activities/") do
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
    activity
    |> Activity.mark_processed_changeset(%{process_attempts: activity.process_attempts + 1})
    |> Repo.update()

    target_user = get_target_user(activity)

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
        error_msg =
          if is_binary(reason) do
            reason
          else
            inspect(reason)
          end

        activity
        |> Activity.mark_processed_changeset(%{process_error: String.slice(error_msg, 0, 255)})
        |> Repo.update()

        if activity.process_attempts >= @max_attempts do
          Logger.warning(
            "Activity #{activity.activity_id} failed after #{@max_attempts} attempts: #{error_msg}"
          )
        end
    end
  end

  defp get_target_user(activity) do
    case activity.object_id do
      nil ->
        nil

      object_id ->
        if String.contains?(object_id, "/users/") do
          case Regex.run(~r{/users/([^/]+)/?}, object_id) do
            [_, username] -> Elektrine.Accounts.get_user_by_username(username)
            _ -> nil
          end
        else
          nil
        end
    end
  end
end
