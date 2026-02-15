defmodule Elektrine.Email.EmailSendWorker do
  @moduledoc """
  Background worker for processing queued email send jobs.

  Processes pending email jobs from the email_jobs table and sends them
  via the existing Sender module. Handles retries and failure states.
  """
  use GenServer

  alias Elektrine.Email.EmailJob
  alias Elektrine.Email.Sender
  alias Elektrine.Repo

  import Ecto.Query

  require Logger

  # Process every 10 seconds (reduced from 5s to decrease pool pressure)
  @process_interval :timer.seconds(10)
  @batch_size 5
  @max_attempts 3

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Queue an email to be sent in the background.

  Returns `{:ok, job}` with the created job record.
  """
  def queue_email(user_id, email_attrs, attachments \\ nil, opts \\ []) do
    scheduled_for = Keyword.get(opts, :scheduled_for)

    attrs = %{
      user_id: user_id,
      email_attrs: email_attrs,
      attachments: attachments,
      scheduled_for: scheduled_for,
      status: "pending"
    }

    %EmailJob{}
    |> EmailJob.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get the status of a queued email job.
  """
  def get_job_status(job_id) do
    case Repo.get(EmailJob, job_id) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  # Server Callbacks

  @impl true
  def init(state) do
    Logger.info("EmailSendWorker started")
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

  defp process_pending_jobs do
    now = DateTime.utc_now()

    # Get pending jobs that are ready to send
    jobs =
      from(j in EmailJob,
        where: j.status == "pending",
        where: j.attempts < ^@max_attempts,
        where: is_nil(j.scheduled_for) or j.scheduled_for <= ^now,
        order_by: [asc: j.inserted_at],
        limit: ^@batch_size,
        preload: [:user]
      )
      |> Repo.all()

    if jobs != [] do
      Logger.info("EmailSendWorker processing #{length(jobs)} pending jobs")
    end

    Enum.each(jobs, &process_job/1)
  end

  defp process_job(job) do
    Logger.info("Processing email job #{job.id} for user #{job.user_id}")

    # Mark as processing
    job
    |> EmailJob.mark_processing_changeset()
    |> Repo.update()

    # Convert stored attrs back to format expected by Sender
    email_attrs = atomize_keys(job.email_attrs)
    attachments = if job.attachments, do: atomize_keys(job.attachments), else: nil

    # Send the email
    case Sender.send_email(job.user_id, email_attrs, attachments) do
      {:ok, _result} ->
        Logger.info("Email job #{job.id} completed successfully")

        job
        |> EmailJob.mark_completed_changeset()
        |> Repo.update()

        # Update user storage after successful send
        Elektrine.Accounts.Storage.update_user_storage(job.user_id)

      {:error, :rate_limit_exceeded} ->
        # Don't count rate limit as a failure - retry later
        Logger.info("Email job #{job.id} rate limited, will retry")

        job
        |> Ecto.Changeset.change(%{status: "pending"})
        |> Repo.update()

      {:error, reason} ->
        Logger.error("Email job #{job.id} failed: #{inspect(reason)}")

        job
        |> EmailJob.mark_failed_changeset(reason)
        |> Repo.update()
    end
  rescue
    e ->
      Logger.error("Email job #{job.id} crashed: #{Exception.message(e)}")

      job
      |> EmailJob.mark_failed_changeset(Exception.message(e))
      |> Repo.update()
  end

  # Convert string keys to atoms for compatibility with Sender
  defp atomize_keys(nil), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), atomize_keys(v)}
      {k, v} when is_atom(k) -> {k, atomize_keys(v)}
    end)
  rescue
    ArgumentError -> map
  end

  defp atomize_keys(value), do: value
end
