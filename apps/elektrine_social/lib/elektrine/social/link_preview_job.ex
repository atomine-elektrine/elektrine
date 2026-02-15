defmodule Elektrine.Social.LinkPreviewJob do
  @moduledoc """
  Schema for queued link preview fetch jobs.

  Link previews are queued here instead of fetched inline, then processed
  by LinkPreviewWorker in the background.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending processing completed failed)

  schema "link_preview_jobs" do
    field :url, :string
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :error, :string
    field :completed_at, :utc_datetime

    belongs_to :message, Elektrine.Messaging.Message
    belongs_to :link_preview, Elektrine.Social.LinkPreview

    timestamps()
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :url,
      :message_id,
      :status,
      :attempts,
      :max_attempts,
      :error,
      :link_preview_id,
      :completed_at
    ])
    |> validate_required([:url])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:link_preview_id)
  end

  def mark_processing_changeset(job) do
    job
    |> change(%{status: "processing", attempts: job.attempts + 1})
  end

  def mark_completed_changeset(job, link_preview_id) do
    job
    |> change(%{
      status: "completed",
      link_preview_id: link_preview_id,
      completed_at: DateTime.utc_now(),
      error: nil
    })
  end

  def mark_failed_changeset(job, error) do
    status = if job.attempts >= job.max_attempts, do: "failed", else: "pending"

    job
    |> change(%{status: status, error: String.slice(to_string(error), 0, 255)})
  end
end
