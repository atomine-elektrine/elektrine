defmodule Elektrine.Workers.LemmyCacheWorker do
  @moduledoc """
  Oban worker for refreshing Lemmy post counts cache in background.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 2

  require Logger

  alias Elektrine.ActivityPub.LemmyCache

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activitypub_ids" => activitypub_ids}}) do
    Logger.debug("LemmyCacheWorker: Refreshing #{length(activitypub_ids)} posts")

    # Process in parallel but with limited concurrency
    activitypub_ids
    |> Task.async_stream(
      fn id -> LemmyCache.refresh_cache(id) end,
      max_concurrency: 5,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, {:ok, _}} -> :ok
      {:ok, {:error, reason}} -> Logger.warning("LemmyCache refresh failed: #{inspect(reason)}")
      {:exit, :timeout} -> Logger.warning("LemmyCache refresh timed out")
      _ -> :ok
    end)

    :ok
  end

  def perform(%Oban.Job{args: %{"activitypub_id" => activitypub_id}}) do
    # Single post refresh
    case LemmyCache.refresh_cache(activitypub_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
