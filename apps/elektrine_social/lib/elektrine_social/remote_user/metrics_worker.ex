defmodule ElektrineSocial.RemoteUser.MetricsWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :federation,
    max_attempts: 3,
    unique: [period: 60, keys: [:actor_id, :type], states: [:available, :scheduled, :executing]]

  alias ElektrineSocial.RemoteUser.Metrics

  def enqueue(actor_id, type)
      when is_integer(actor_id) and actor_id > 0 and type in ["counts", "community_stats"] do
    %{"actor_id" => actor_id, "type" => type}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue(_, _), do: {:error, :invalid_metrics_job}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"actor_id" => actor_id, "type" => "counts"}}) do
    case Metrics.refresh_counts(actor_id) do
      {:ok, _} -> :ok
      {:error, :actor_not_found} -> {:discard, :actor_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"actor_id" => actor_id, "type" => "community_stats"}}) do
    case Metrics.refresh_community_stats(actor_id) do
      {:ok, _} -> :ok
      {:error, :actor_not_found} -> {:discard, :actor_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
