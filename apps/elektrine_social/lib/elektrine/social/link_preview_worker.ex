defmodule Elektrine.Social.LinkPreviewWorker do
  @moduledoc """
  Background worker for processing queued link preview fetch jobs.

  Processes pending link preview jobs from the link_preview_jobs table,
  fetches the URL metadata, and updates the associated LinkPreview record.
  """
  use GenServer

  alias Elektrine.Social.LinkPreviewJob
  alias Elektrine.Social.LinkPreview
  alias Elektrine.Social.LinkPreviewFetcher
  alias Elektrine.Repo

  import Ecto.Query

  require Logger

  # Process every 15 seconds (reduced from 3s to decrease HTTP pool pressure)
  @process_interval :timer.seconds(15)
  # Process fewer items per batch
  @batch_size 5
  @max_attempts 3

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Queue a URL for link preview fetching.

  Returns `{:ok, job}` with the created job record.
  If a preview already exists for the URL, returns `{:ok, :exists}`.
  """
  def queue_preview(url, message_id \\ nil) do
    # Check if preview already exists and is complete
    case Repo.get_by(LinkPreview, url: url) do
      %LinkPreview{status: "success"} = preview ->
        # Already have a successful preview
        {:ok, {:exists, preview}}

      %LinkPreview{status: "pending"} ->
        # Already being fetched, check for existing job
        existing_job =
          from(j in LinkPreviewJob,
            where: j.url == ^url and j.status in ["pending", "processing"]
          )
          |> Repo.one()

        case existing_job do
          nil ->
            # No job exists, create one
            create_job(url, message_id)

          job ->
            {:ok, {:queued, job}}
        end

      _ ->
        # No preview or failed, queue a new job
        create_job(url, message_id)
    end
  end

  @doc """
  Queue multiple URLs for link preview fetching.
  """
  def queue_previews(urls, message_id \\ nil) when is_list(urls) do
    Enum.map(urls, fn url -> queue_preview(url, message_id) end)
  end

  @doc """
  Get the status of a queued link preview job.
  """
  def get_job_status(job_id) do
    case Repo.get(LinkPreviewJob, job_id) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  # Server Callbacks

  @impl true
  def init(state) do
    Logger.info("LinkPreviewWorker started")
    schedule_processing()
    {:ok, state}
  end

  @impl true
  def handle_info(:process_jobs, state) do
    process_pending_jobs()
    schedule_processing()
    {:noreply, state}
  end

  # Private Functions

  defp schedule_processing do
    Process.send_after(self(), :process_jobs, @process_interval)
  end

  defp create_job(url, message_id) do
    # First ensure we have a pending LinkPreview record
    preview =
      case Repo.get_by(LinkPreview, url: url) do
        nil ->
          case %LinkPreview{}
               |> LinkPreview.changeset(%{url: url, status: "pending"})
               |> Repo.insert() do
            {:ok, p} ->
              p

            {:error, _} ->
              # Race condition - try fetching again
              Repo.get_by(LinkPreview, url: url)
          end

        existing ->
          existing
      end

    # Create job
    attrs = %{
      url: url,
      message_id: message_id,
      status: "pending"
    }

    case %LinkPreviewJob{}
         |> LinkPreviewJob.changeset(attrs)
         |> Repo.insert() do
      {:ok, job} ->
        {:ok, {:queued, job, preview}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp process_pending_jobs do
    # Get pending jobs
    jobs =
      from(j in LinkPreviewJob,
        where: j.status == "pending",
        where: j.attempts < ^@max_attempts,
        order_by: [asc: j.inserted_at],
        limit: ^@batch_size
      )
      |> Repo.all()

    if jobs != [] do
      Logger.info("LinkPreviewWorker processing #{length(jobs)} pending jobs")
    end

    Enum.each(jobs, &process_job/1)
  end

  defp process_job(job) do
    Logger.info("Processing link preview job #{job.id} for URL: #{job.url}")

    # Mark as processing
    job
    |> LinkPreviewJob.mark_processing_changeset()
    |> Repo.update()

    # Fetch the metadata
    metadata = LinkPreviewFetcher.fetch_preview_metadata(job.url)

    # Find or create the preview record
    preview =
      case Repo.get_by(LinkPreview, url: job.url) do
        nil ->
          # Create new
          case %LinkPreview{}
               |> LinkPreview.changeset(Map.put(metadata, :url, job.url))
               |> Repo.insert() do
            {:ok, p} -> p
            {:error, _} -> Repo.get_by(LinkPreview, url: job.url)
          end

        existing ->
          # Update existing
          case LinkPreviewFetcher.update_preview_with_metadata(existing, metadata) do
            {:ok, p} -> p
            {:error, _} -> existing
          end
      end

    if preview && metadata[:status] == "success" do
      Logger.info("Link preview job #{job.id} completed successfully")

      job
      |> LinkPreviewJob.mark_completed_changeset(preview.id)
      |> Repo.update()

      # Broadcast update if there's an associated message
      if job.message_id do
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "message:#{job.message_id}",
          {:link_preview_ready, job.message_id, preview}
        )
      end
    else
      error = metadata[:error_message] || "Unknown error"
      Logger.warning("Link preview job #{job.id} failed: #{error}")

      job
      |> LinkPreviewJob.mark_failed_changeset(error)
      |> Repo.update()
    end
  rescue
    e ->
      Logger.error("Link preview job #{job.id} crashed: #{Exception.message(e)}")

      job
      |> LinkPreviewJob.mark_failed_changeset(Exception.message(e))
      |> Repo.update()
  end
end
