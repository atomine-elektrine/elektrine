defmodule Elektrine.Email.EmailJob do
  @moduledoc """
  Legacy schema for the old custom `email_jobs` queue.

  New outbound deliveries are scheduled in Oban via
  `Elektrine.Email.SendEmailWorker`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending processing completed failed)

  schema "email_jobs" do
    field :status, :string, default: "pending"
    field :email_attrs, :map
    field :attachments, :map
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :error, :string
    field :completed_at, :utc_datetime
    field :scheduled_for, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :user_id,
      :status,
      :email_attrs,
      :attachments,
      :attempts,
      :max_attempts,
      :error,
      :completed_at,
      :scheduled_for
    ])
    |> validate_required([:user_id, :email_attrs])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
  end

  def mark_processing_changeset(job) do
    job
    |> change(%{status: "processing", attempts: job.attempts + 1})
  end

  def mark_completed_changeset(job) do
    job
    |> change(%{status: "completed", completed_at: DateTime.utc_now(), error: nil})
  end

  def mark_failed_changeset(job, error) do
    status = if job.attempts >= job.max_attempts, do: "failed", else: "pending"

    job
    |> change(%{status: status, error: String.slice(to_string(error), 0, 255)})
  end
end
