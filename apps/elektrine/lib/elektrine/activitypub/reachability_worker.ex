defmodule Elektrine.ActivityPub.ReachabilityWorker do
  @moduledoc """
  Probes unreachable ActivityPub domains once their backoff window has elapsed.
  """

  use Oban.Worker,
    queue: :federation_metadata,
    max_attempts: 1,
    priority: 9,
    unique: [
      period: 1_800,
      keys: [:type, :domain],
      states: [:available, :scheduled, :executing]
    ]

  import Ecto.Query

  require Logger

  alias Elektrine.ActivityPub.{Instance, Instances}
  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.Repo

  @default_limit 100

  def enqueue_due(limit \\ @default_limit) do
    %{"type" => "due", "limit" => limit}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue_domain(domain) when is_binary(domain) do
    %{"type" => "domain", "domain" => normalize_domain(domain)}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "due"} = args}) do
    limit = args |> Map.get("limit", @default_limit) |> clamp_limit()

    Instance
    |> where([i], not is_nil(i.unreachable_since))
    |> where([i], i.blocked == false)
    |> order_by([i], asc: i.unreachable_since)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.filter(&Instances.should_retry?(&1.domain))
    |> Enum.each(&enqueue_domain(&1.domain))

    :ok
  end

  def perform(%Oban.Job{args: %{"type" => "domain", "domain" => domain}}) do
    case probe(domain) do
      :ok ->
        _ = Instances.set_reachable(domain)
        :ok

      {:error, reason} ->
        Logger.debug("Reachability probe failed for #{domain}: #{inspect(reason)}")
        :ok
    end
  end

  defp probe(domain) do
    url = "https://#{normalize_domain(domain)}/.well-known/nodeinfo"

    case Finch.build(:get, url, [{"accept", "application/json"}])
         |> SafeFetch.request(Elektrine.Finch, receive_timeout: 5_000, max_body_bytes: 50_000) do
      {:ok, %Finch.Response{status: status}} when status in 200..399 -> :ok
      {:ok, %Finch.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clamp_limit(limit) when is_integer(limit), do: max(1, min(limit, @default_limit))
  defp clamp_limit(_limit), do: @default_limit

  defp normalize_domain(domain), do: domain |> String.trim() |> String.downcase()
end
