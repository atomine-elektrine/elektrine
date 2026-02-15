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
    Federation.process_outbox_event(outbox_event_id)
    :ok
  end

  @doc """
  Enqueue a single outbox event for immediate processing.
  """
  def enqueue(outbox_event_id) when is_integer(outbox_event_id) do
    %{outbox_event_id: outbox_event_id}
    |> new()
    |> Oban.insert()
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
      Oban.insert_all(jobs)
    end
  end
end
