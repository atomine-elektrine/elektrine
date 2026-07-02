defmodule Elektrine.ActivityPub.ActorRefreshWorker do
  @moduledoc """
  Bounded refresh of stale remote actors and their profile metadata.
  """

  use Oban.Worker,
    queue: :federation_metadata,
    max_attempts: 2,
    priority: 8,
    unique: [
      period: 3_600,
      keys: [:type, :actor_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  alias Elektrine.ActivityPub.{Actor, FederationLoadGuard}
  alias Elektrine.Repo

  @default_limit 200
  @stale_hours 24

  def enqueue(actor_id) when is_integer(actor_id) do
    %{"type" => "single", "actor_id" => actor_id}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue_stale(limit \\ @default_limit) do
    %{"type" => "stale", "limit" => limit}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "stale"} = args}) do
    if FederationLoadGuard.skip_nonessential?(__MODULE__) do
      {:discard, :federation_overloaded}
    else
      args
      |> Map.get("limit", @default_limit)
      |> enqueue_stale_actor_batch()

      :ok
    end
  end

  def perform(%Oban.Job{args: %{"type" => "single", "actor_id" => actor_id}})
      when is_integer(actor_id) do
    if FederationLoadGuard.skip_nonessential?(__MODULE__) do
      {:discard, :federation_overloaded}
    else
      refresh_actor(actor_id)
    end
  end

  defp enqueue_stale_actor_batch(limit) do
    limit = max(1, min(limit || @default_limit, @default_limit))
    cutoff = DateTime.utc_now() |> DateTime.add(-@stale_hours, :hour)

    Actor
    |> where([a], not is_nil(a.uri))
    |> where([a], is_nil(a.last_fetched_at) or a.last_fetched_at < ^cutoff)
    |> order_by([a], asc: a.last_fetched_at, asc: a.id)
    |> limit(^limit)
    |> select([a], a.id)
    |> Repo.all()
    |> Enum.each(&enqueue/1)
  end

  defp refresh_actor(actor_id) do
    case Repo.get(Actor, actor_id) do
      %Actor{uri: uri} when is_binary(uri) ->
        case Elektrine.ActivityPub.get_or_fetch_actor(uri) do
          {:ok, _actor} -> :ok
          {:error, :invalid_actor_uri} -> {:discard, :invalid_actor_uri}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:discard, :actor_not_found}

      _actor ->
        {:discard, :missing_actor_uri}
    end
  end
end
