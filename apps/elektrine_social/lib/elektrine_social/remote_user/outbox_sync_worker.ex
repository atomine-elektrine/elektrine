defmodule ElektrineSocial.RemoteUser.OutboxSyncWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :federation,
    max_attempts: 3,
    unique: [period: 60, keys: [:actor_id], states: [:available, :scheduled, :executing]]

  alias ElektrineSocial.RemoteUser.OutboxSync

  def enqueue(actor_id, opts \\ [])

  def enqueue(actor_id, opts) when is_integer(actor_id) and actor_id > 0 do
    limit = Keyword.get(opts, :limit, 20)

    %{"actor_id" => actor_id, "limit" => limit}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue(_, _), do: {:error, :invalid_actor_id}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"actor_id" => actor_id, "limit" => limit}}) do
    case OutboxSync.sync_actor_outbox(actor_id, limit) do
      {:ok, _posts} -> :ok
      {:error, :actor_not_found} -> {:discard, :actor_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
