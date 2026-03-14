defmodule Elektrine.Jobs.StaleCallCleanup do
  @moduledoc """
  Oban worker that cleans up stale calls that never completed.

  Calls stuck in "initiated" or "ringing" for more than 5 minutes
  are automatically marked as "missed" to prevent database pollution
  and blocking new calls.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger
  alias Elektrine.Calls.Call
  alias Elektrine.Repo
  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    run()
    :ok
  end

  def run do
    one_minute_ago = DateTime.utc_now() |> DateTime.add(-60, :second)
    ten_minutes_ago = DateTime.utc_now() |> DateTime.add(-600, :second)

    # Clean up calls stuck in initiated/ringing state (1 minute - unanswered calls)
    {initiated_count, _} =
      from(c in Call,
        where: c.status in ["initiated", "ringing"],
        where: c.inserted_at < ^one_minute_ago
      )
      |> Repo.update_all(
        set: [
          status: "missed",
          ended_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        ]
      )

    # Clean up calls stuck in active state (10 minutes - these are hanging calls)
    {active_count, _} =
      from(c in Call,
        where: c.status == "active",
        where: c.inserted_at < ^ten_minutes_ago
      )
      |> Repo.update_all(
        set: [
          status: "ended",
          ended_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        ]
      )

    total_count = initiated_count + active_count

    if total_count > 0 do
      Logger.info(
        "Cleaned up #{total_count} stale calls (#{initiated_count} initiated/ringing, #{active_count} active)"
      )
    end

    :ok
  end

  def enqueue do
    %{}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  @doc """
  Force cleanup any active calls for a specific user.
  Useful when a user tries to initiate a new call but has a hanging call.
  """
  def cleanup_user_calls(user_id) do
    {count, _} =
      from(c in Call,
        where: c.status in ["initiated", "ringing", "active"],
        where: c.caller_id == ^user_id or c.callee_id == ^user_id
      )
      |> Repo.update_all(
        set: [
          status: "failed",
          ended_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        ]
      )

    if count > 0 do
      Logger.info("Force cleaned up #{count} hanging calls for user #{user_id}")
    end

    :ok
  end
end
