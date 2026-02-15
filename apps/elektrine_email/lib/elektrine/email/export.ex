defmodule Elektrine.Email.Export do
  @moduledoc """
  Schema for email export jobs.
  Tracks the status of email export requests.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_exports" do
    field :status, :string, default: "pending"
    field :format, :string, default: "mbox"
    field :file_path, :string
    field :file_size, :integer
    field :message_count, :integer
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :error, :string
    field :filters, :map, default: %{}

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @valid_statuses ~w(pending processing completed failed)
  @valid_formats ~w(mbox eml zip)

  @doc """
  Creates a changeset for an export job.
  """
  def changeset(export, attrs) do
    export
    |> cast(attrs, [
      :status,
      :format,
      :file_path,
      :file_size,
      :message_count,
      :started_at,
      :completed_at,
      :error,
      :filters,
      :user_id
    ])
    |> validate_required([:user_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:format, @valid_formats)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Marks an export as started.
  """
  def start_changeset(export) do
    export
    |> change()
    |> put_change(:status, "processing")
    |> put_change(:started_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Marks an export as completed.
  """
  def complete_changeset(export, file_path, file_size, message_count) do
    export
    |> change()
    |> put_change(:status, "completed")
    |> put_change(:file_path, file_path)
    |> put_change(:file_size, file_size)
    |> put_change(:message_count, message_count)
    |> put_change(:completed_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Marks an export as failed.
  """
  def fail_changeset(export, error) do
    export
    |> change()
    |> put_change(:status, "failed")
    |> put_change(:error, error)
    |> put_change(:completed_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end
end
