defmodule Elektrine.JMAP.EmailSubmission do
  @moduledoc """
  Schema for JMAP EmailSubmission. Tracks outbound email delivery status.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.JMAP
  alias Elektrine.Repo

  @undo_statuses ~w(pending final canceled)

  schema "email_submissions" do
    field :identity_id, :string
    field :envelope_from, :string
    field :envelope_to, {:array, :string}, default: []
    field :send_at, :utc_datetime
    field :undo_status, :string, default: "pending"
    field :delivery_status, :map, default: %{}

    belongs_to :mailbox, Elektrine.Email.Mailbox
    belongs_to :email, Elektrine.Email.Message

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a new email submission.
  """
  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [
      :mailbox_id,
      :email_id,
      :identity_id,
      :envelope_from,
      :envelope_to,
      :send_at,
      :undo_status,
      :delivery_status
    ])
    |> validate_required([:mailbox_id, :identity_id, :envelope_from, :envelope_to])
    |> validate_inclusion(:undo_status, @undo_statuses)
    |> validate_length(:envelope_to, min: 1)
  end

  @doc """
  Creates a new email submission.
  """
  def create(attrs) do
    result =
      %__MODULE__{}
      |> changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, submission} ->
        JMAP.bump_states(submission.mailbox_id, ["EmailSubmission"])
        {:ok, submission}

      error ->
        error
    end
  end

  @doc """
  Gets an email submission by ID.
  """
  def get(id, mailbox_id) do
    Repo.one(
      from s in __MODULE__,
        where: s.id == ^id and s.mailbox_id == ^mailbox_id
    )
  end

  @doc """
  Gets an email submission by ID without mailbox scoping for internal jobs.
  """
  def get(id) do
    Repo.get(__MODULE__, id)
  end

  @doc """
  Gets the most recent submission for a specific email in a mailbox.
  """
  def get_by_email(mailbox_id, email_id) do
    Repo.one(
      from s in __MODULE__,
        where: s.mailbox_id == ^mailbox_id and s.email_id == ^email_id,
        order_by: [desc: s.inserted_at],
        limit: 1
    )
  end

  @doc """
  Lists email submissions for a mailbox.
  """
  def list(mailbox_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    Repo.all(
      from s in __MODULE__,
        where: s.mailbox_id == ^mailbox_id,
        order_by: [desc: s.inserted_at],
        limit: ^limit,
        offset: ^offset
    )
  end

  @doc """
  Updates the delivery status for a submission.
  """
  def update_delivery_status(submission, recipient, status) do
    new_status = Map.put(submission.delivery_status, recipient, status)

    update_submission(submission, %{delivery_status: new_status})
  end

  @doc """
  Updates a submission with the provided attributes.
  """
  def update(submission, attrs) when is_map(attrs) do
    update_submission(submission, attrs)
  end

  @doc """
  Cancels a pending submission (undo send).
  Only works if undo_status is "pending" and send_at hasn't passed.
  """
  def cancel(submission) do
    if submission.undo_status == "pending" do
      now = DateTime.utc_now()

      if is_nil(submission.send_at) or DateTime.compare(now, submission.send_at) == :lt do
        delivery_status =
          submission.delivery_status
          |> normalize_delivery_status()
          |> Map.put("status", "canceled")

        update_submission(submission, %{undo_status: "canceled", delivery_status: delivery_status})
      else
        {:error, :too_late}
      end
    else
      {:error, :already_final}
    end
  end

  @doc """
  Marks a submission as final (sent).
  """
  def finalize(submission) do
    update_submission(submission, %{undo_status: "final"})
  end

  @doc """
  Marks a submission as sent and records delivery metadata.
  """
  def finalize(submission, delivery_status) when is_map(delivery_status) do
    update_submission(submission, %{
      undo_status: "final",
      delivery_status: delivery_status
    })
  end

  @doc """
  Marks a submission as failed and records the failure reason.
  """
  def fail(submission, reason) do
    delivery_status =
      submission.delivery_status
      |> normalize_delivery_status()
      |> Map.merge(%{
        "status" => "failed",
        "error" => format_reason(reason)
      })

    update_submission(submission, %{
      undo_status: "final",
      delivery_status: delivery_status
    })
  end

  @doc """
  Gets submissions changed since a state.
  """
  def get_changes_since(mailbox_id, since_state) do
    _since_int =
      case Integer.parse(since_state) do
        {int, ""} -> int
        _ -> 0
      end

    # Get all submissions that were created or updated after the since_state
    # In a real implementation, we'd track which records changed
    # Return all submissions for now because change tracking is not implemented.
    list(mailbox_id)
  end

  defp update_submission(submission, attrs) do
    result =
      submission
      |> cast(attrs, [:send_at, :undo_status, :delivery_status])
      |> Repo.update()

    case result do
      {:ok, updated_submission} ->
        JMAP.bump_states(updated_submission.mailbox_id, ["EmailSubmission"])
        {:ok, updated_submission}

      error ->
        error
    end
  end

  defp normalize_delivery_status(status) when is_map(status), do: status
  defp normalize_delivery_status(_), do: %{}

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
