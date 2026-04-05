defmodule Elektrine.Messaging.FederationOutboxWorker do
  @moduledoc """
  Processes one messaging federation outbox row.
  """

  use Oban.Worker,
    queue: :messaging_federation,
    max_attempts: 1,
    unique: [period: 300, fields: [:args], keys: [:outbox_event_id]]

  alias Elektrine.Messaging.Federation

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"outbox_event_id" => outbox_event_id}}) do
    case Federation.process_outbox_event(outbox_event_id) do
      :delivered -> :ok
      :pending_retry -> :ok
      :already_delivered -> {:discard, :already_delivered}
      :already_failed -> {:discard, :already_failed}
      :not_due -> {:discard, :not_due}
      :not_found -> {:discard, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_result, other}}
    end
  end

  @doc """
  Enqueue a single outbox event for immediate processing.
  """
  def enqueue(outbox_event_id) when is_integer(outbox_event_id) do
    %{outbox_event_id: outbox_event_id}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  @doc """
  Enqueue many outbox events in one DB call.
  """
  def enqueue_many(outbox_event_ids) when is_list(outbox_event_ids) do
    jobs =
      outbox_event_ids
      |> Enum.uniq()
      |> Enum.map(fn id -> new(%{outbox_event_id: id}) end)

    if jobs == [] do
      {:ok, []}
    else
      Elektrine.JobQueue.insert_all(jobs)
    end
  end
end
