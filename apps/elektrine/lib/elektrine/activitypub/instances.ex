defmodule Elektrine.ActivityPub.Instances do
  @moduledoc """
  Context for managing ActivityPub instance reachability and federation status.

  Tracks which remote instances are reachable and implements smart delivery
  filtering to avoid wasting resources on dead instances.
  """

  import Ecto.Query
  alias Elektrine.ActivityPub.Instance
  alias Elektrine.ActivityPub.NodeInfoFetcherWorker
  alias Elektrine.Repo

  @doc """
  Checks if a domain is reachable.
  Returns true if no unreachable record exists or if the instance has recovered.
  """
  def reachable?(domain) when is_binary(domain) do
    domain = normalize_domain(domain)

    case get_instance(domain) do
      nil -> true
      instance -> Instance.reachable?(instance)
    end
  end

  @doc """
  Filters a list of inbox URLs to only include reachable instances.
  """
  def filter_reachable(inbox_urls) when is_list(inbox_urls) do
    Enum.filter(inbox_urls, fn url ->
      uri = URI.parse(url)
      reachable?(uri.host)
    end)
  end

  @doc """
  Marks an instance as unreachable after a delivery failure.
  Creates the instance record if it doesn't exist.
  """
  def set_unreachable(domain) when is_binary(domain) do
    domain = normalize_domain(domain)

    case get_or_create_instance(domain) do
      {:ok, instance} ->
        instance
        |> Instance.set_unreachable_changeset()
        |> Repo.update()

      error ->
        error
    end
  end

  @doc """
  Marks an instance as reachable after a successful delivery.
  Only updates if the instance record exists.
  """
  def set_reachable(domain) when is_binary(domain) do
    domain = normalize_domain(domain)

    case get_instance(domain) do
      nil ->
        {:ok, :no_record}

      instance ->
        if instance.unreachable_since do
          instance
          |> Instance.set_reachable_changeset()
          |> Repo.update()
        else
          {:ok, instance}
        end
    end
  end

  @doc """
  Gets an instance record by domain.
  """
  def get_instance(domain) when is_binary(domain) do
    domain = normalize_domain(domain)
    Repo.get_by(Instance, domain: domain)
  end

  @doc """
  Gets or creates an instance record for a domain.
  """
  def get_or_create_instance(domain) when is_binary(domain) do
    domain = normalize_domain(domain)

    case get_instance(domain) do
      nil ->
        %Instance{}
        |> Instance.changeset(%{domain: domain})
        |> Repo.insert()

      instance ->
        {:ok, instance}
    end
  end

  @doc """
  Returns a list of consistently unreachable instances.
  These are instances that have been unreachable for longer than the timeout period.
  """
  def get_consistently_unreachable do
    timeout_days = Application.get_env(:elektrine, :federation_reachability_timeout_days, 7)
    cutoff = DateTime.add(DateTime.utc_now(), -timeout_days * 24 * 60 * 60, :second)

    Instance
    |> where([i], not is_nil(i.unreachable_since))
    |> where([i], i.unreachable_since < ^cutoff)
    |> order_by([i], desc: i.failure_count)
    |> Repo.all()
  end

  @doc """
  Returns a list of currently unreachable instances (within timeout period).
  """
  def get_unreachable do
    Instance
    |> where([i], not is_nil(i.unreachable_since))
    |> order_by([i], desc: i.unreachable_since)
    |> Repo.all()
  end

  @doc """
  Returns statistics about instance reachability.
  """
  def reachability_stats do
    total_query = from(i in Instance, select: count(i.id))

    unreachable_query =
      from(i in Instance, where: not is_nil(i.unreachable_since), select: count(i.id))

    timeout_days = Application.get_env(:elektrine, :federation_reachability_timeout_days, 7)
    cutoff = DateTime.add(DateTime.utc_now(), -timeout_days * 24 * 60 * 60, :second)

    dead_query =
      from(i in Instance,
        where: not is_nil(i.unreachable_since) and i.unreachable_since < ^cutoff,
        select: count(i.id)
      )

    %{
      total_tracked: Repo.one(total_query) || 0,
      currently_unreachable: Repo.one(unreachable_query) || 0,
      consistently_dead: Repo.one(dead_query) || 0
    }
  end

  @doc """
  Checks if we should attempt delivery to a domain based on backoff.
  """
  def should_retry?(domain) when is_binary(domain) do
    domain = normalize_domain(domain)

    case get_instance(domain) do
      nil ->
        true

      %{unreachable_since: nil} ->
        true

      instance ->
        backoff_seconds = Instance.backoff_duration(instance)
        backoff_until = DateTime.add(instance.unreachable_since, backoff_seconds, :second)
        DateTime.compare(DateTime.utc_now(), backoff_until) == :gt
    end
  end

  @doc """
  Cleans up old unreachable records that have exceeded the timeout period.
  Called periodically to prevent unbounded growth.
  """
  def cleanup_old_records do
    timeout_days = Application.get_env(:elektrine, :federation_reachability_timeout_days, 7)
    # Keep records for 3x the timeout period before cleanup
    cleanup_cutoff = DateTime.add(DateTime.utc_now(), -timeout_days * 3 * 24 * 60 * 60, :second)

    # Only clean up instances that have no MRF policies and are just reachability records
    from(i in Instance,
      where: not is_nil(i.unreachable_since),
      where: i.unreachable_since < ^cleanup_cutoff,
      where: i.blocked == false,
      where: i.silenced == false,
      where: i.media_removal == false,
      where: i.media_nsfw == false,
      where: i.federated_timeline_removal == false,
      where: i.followers_only == false,
      where: i.report_removal == false,
      where: i.avatar_removal == false,
      where: i.banner_removal == false,
      where: i.reject_deletes == false
    )
    |> Repo.delete_all()
  end

  defp normalize_domain(domain) do
    domain
    |> String.trim()
    |> String.downcase()
  end

  # NodeInfo / Metadata functions

  @doc """
  Enqueues a background job to fetch nodeinfo for a domain.
  Safe to call frequently - jobs are deduplicated and metadata is only
  refreshed if older than 24 hours.
  """
  def fetch_metadata(domain) when is_binary(domain) do
    NodeInfoFetcherWorker.enqueue(domain)
  end

  @doc """
  Enqueues a background job to fetch nodeinfo for a domain extracted from a URL.
  """
  def fetch_metadata_from_url(url) when is_binary(url) do
    NodeInfoFetcherWorker.enqueue_from_url(url)
  end

  @doc """
  Gets instance with nodeinfo for a domain.
  Optionally triggers a background fetch if metadata is stale.
  """
  def get_instance_with_metadata(domain, opts \\ []) when is_binary(domain) do
    domain = normalize_domain(domain)
    instance = get_instance(domain)

    if opts[:fetch_if_stale] && Instance.needs_metadata_update?(instance) do
      fetch_metadata(domain)
    end

    instance
  end

  @doc """
  Gets software name for a domain from stored nodeinfo.
  Returns nil if not known.
  """
  def get_software(domain) when is_binary(domain) do
    domain = normalize_domain(domain)

    case get_instance(domain) do
      %Instance{} = instance -> Instance.software_name(instance)
      nil -> nil
    end
  end

  @doc """
  Gets software info for multiple domains in a single query.
  Returns a map of domain => software_name.
  """
  def get_software_batch(domains) when is_list(domains) do
    domains = Enum.map(domains, &normalize_domain/1) |> Enum.uniq()

    Instance
    |> where([i], i.domain in ^domains)
    |> where([i], not is_nil(i.nodeinfo))
    |> select([i], {i.domain, i.nodeinfo})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {domain, nodeinfo}, acc ->
      case get_in(nodeinfo, ["software", "name"]) do
        name when is_binary(name) -> Map.put(acc, domain, String.downcase(name))
        _ -> acc
      end
    end)
  end

  @doc """
  Lists instances with their metadata, with optional filters.
  """
  def list_instances_with_metadata(opts \\ []) do
    Instance
    |> maybe_filter_by_software(opts[:software])
    |> maybe_filter_has_metadata(opts[:has_metadata])
    |> order_by([i], desc: i.metadata_updated_at)
    |> limit(^(opts[:limit] || 100))
    |> Repo.all()
  end

  defp maybe_filter_by_software(query, nil), do: query

  defp maybe_filter_by_software(query, software) do
    software = String.downcase(software)

    where(
      query,
      [i],
      fragment("lower(?->'software'->>'name') = ?", i.nodeinfo, ^software)
    )
  end

  defp maybe_filter_has_metadata(query, true) do
    where(query, [i], not is_nil(i.metadata_updated_at))
  end

  defp maybe_filter_has_metadata(query, _), do: query
end
