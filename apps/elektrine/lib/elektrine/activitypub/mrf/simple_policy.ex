defmodule Elektrine.ActivityPub.MRF.SimplePolicy do
  @moduledoc """
  Simple domain-based MRF policy using database-stored instance policies.

  Provides filtering capabilities based on Instance records:
  - Reject: Block activities from instance (blocked = true)
  - Media removal: Strip media from activities
  - Media NSFW: Mark all media as sensitive
  - Federated timeline removal: Remove from public timeline
  - Followers only: Force posts to followers-only visibility
  - Report rejection: Reject Flag activities
  - Avatar/Banner removal: Strip profile images
  - Reject deletes: Reject Delete activities

  ## Caching

  Instance policies are cached in ETS for performance. Cache is invalidated
  when instances are updated via the Federation admin interface.

  ## Fallback

  Also supports config-based lists as fallback:

      config :elektrine, :mrf_simple,
        reject: [{"spam.example.com", "Known spam instance"}]
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  alias Elektrine.ActivityPub.Instance
  alias Elektrine.ActivityPub.MRF
  alias Elektrine.Repo

  import Ecto.Query

  require Logger

  # Cache table name
  @cache_table :mrf_simple_policy_cache
  # Cache TTL in milliseconds (5 minutes)
  @cache_ttl 300_000

  @impl true
  # Handle Delete activities separately - must be before generic actor clause
  def filter(%{"type" => "Delete", "actor" => actor} = activity) when is_binary(actor) do
    host = MRF.get_actor_host(activity)

    # First check if blocked entirely
    if host_has_policy?(host, :blocked) do
      {:reject, "[SimplePolicy] host is blocked"}
    else
      if host_has_policy?(host, :reject_deletes) do
        {:reject, "[SimplePolicy] host in reject_deletes list"}
      else
        {:ok, activity}
      end
    end
  end

  def filter(%{"actor" => actor} = activity) when is_binary(actor) do
    host = MRF.get_actor_host(activity)

    with {:ok, _} <- check_reject(host),
         {:ok, activity} <- check_media_removal(host, activity),
         {:ok, activity} <- check_media_nsfw(host, activity),
         {:ok, activity} <- check_ftl_removal(host, activity) do
      with {:ok, activity} <- check_followers_only(host, activity) do
        check_report_removal(host, activity)
      end
    end
  end

  # Handle actor objects (Person, Group, etc.)
  def filter(%{"id" => id, "type" => type} = object)
      when type in ["Person", "Group", "Organization", "Service", "Application"] do
    host = URI.parse(id).host

    with {:ok, _} <- check_reject(host),
         {:ok, object} <- check_avatar_removal(host, object) do
      check_banner_removal(host, object)
    end
  end

  # Pass through anything else
  def filter(activity), do: {:ok, activity}

  # Check if host is blocked (reject list)
  defp check_reject(host) do
    if host_has_policy?(host, :blocked) do
      {:reject, "[SimplePolicy] host is blocked"}
    else
      {:ok, nil}
    end
  end

  # Strip media attachments from listed domains
  defp check_media_removal(
         host,
         %{"type" => type, "object" => %{"attachment" => attachments} = object} = activity
       )
       when type in ["Create", "Update"] and is_list(attachments) and attachments != [] do
    if host_has_policy?(host, :media_removal) do
      Logger.info("[SimplePolicy] Removing media from #{host}")
      updated_object = Map.delete(object, "attachment")
      {:ok, Map.put(activity, "object", updated_object)}
    else
      {:ok, activity}
    end
  end

  defp check_media_removal(_host, activity), do: {:ok, activity}

  # Mark all media as sensitive from listed domains
  defp check_media_nsfw(host, %{"type" => type, "object" => object} = activity)
       when type in ["Create", "Update"] and is_map(object) do
    if host_has_policy?(host, :media_nsfw) do
      Logger.debug("[SimplePolicy] Marking content from #{host} as sensitive")
      updated_object = Map.put(object, "sensitive", true)
      {:ok, Map.put(activity, "object", updated_object)}
    else
      {:ok, activity}
    end
  end

  defp check_media_nsfw(_host, activity), do: {:ok, activity}

  # Remove from federated timeline (move Public to CC)
  defp check_ftl_removal(host, %{"to" => to, "cc" => cc} = activity)
       when is_list(to) and is_list(cc) do
    public_uri = "https://www.w3.org/ns/activitystreams#Public"

    if host_has_policy?(host, :federated_timeline_removal) and public_uri in to do
      Logger.debug("[SimplePolicy] Removing #{host} activity from federated timeline")

      updated_to = List.delete(to, public_uri)
      updated_cc = if public_uri in cc, do: cc, else: [public_uri | cc]

      activity =
        activity
        |> Map.put("to", updated_to)
        |> Map.put("cc", updated_cc)

      {:ok, activity}
    else
      {:ok, activity}
    end
  end

  defp check_ftl_removal(_host, activity), do: {:ok, activity}

  # Force posts to followers-only visibility
  defp check_followers_only(host, %{"to" => to, "cc" => cc, "actor" => actor} = activity)
       when is_list(to) and is_list(cc) do
    public_uri = "https://www.w3.org/ns/activitystreams#Public"

    if host_has_policy?(host, :followers_only) and public_uri in to do
      Logger.debug("[SimplePolicy] Forcing #{host} activity to followers-only")

      # Remove public from both to and cc, keep only followers
      # Extract follower collection from actor if possible
      follower_collection = "#{actor}/followers"

      updated_to = to |> List.delete(public_uri) |> ensure_contains(follower_collection)
      updated_cc = List.delete(cc, public_uri)

      activity =
        activity
        |> Map.put("to", updated_to)
        |> Map.put("cc", updated_cc)

      {:ok, activity}
    else
      {:ok, activity}
    end
  end

  defp check_followers_only(_host, activity), do: {:ok, activity}

  defp ensure_contains(list, item) do
    if item in list, do: list, else: [item | list]
  end

  # Reject reports from listed domains
  defp check_report_removal(host, %{"type" => "Flag"} = _activity) do
    if host_has_policy?(host, :report_removal) do
      {:reject, "[SimplePolicy] host in report_removal list"}
    else
      {:ok, nil}
    end
  end

  defp check_report_removal(_host, activity), do: {:ok, activity}

  # Strip avatars from listed domains
  defp check_avatar_removal(host, %{"icon" => _} = object) do
    if host_has_policy?(host, :avatar_removal) do
      {:ok, Map.delete(object, "icon")}
    else
      {:ok, object}
    end
  end

  defp check_avatar_removal(_host, object), do: {:ok, object}

  # Strip banners from listed domains
  defp check_banner_removal(host, %{"image" => _} = object) do
    if host_has_policy?(host, :banner_removal) do
      {:ok, Map.delete(object, "image")}
    else
      {:ok, object}
    end
  end

  defp check_banner_removal(_host, object), do: {:ok, object}

  @doc """
  Checks if a host has a specific policy active.
  Uses cached data for performance with fallback to database.
  """
  def host_has_policy?(host, policy_type) when is_binary(host) and is_atom(policy_type) do
    # Check cache first
    case get_cached_policies(host) do
      {:ok, policies} ->
        Map.get(policies, policy_type, false)

      :miss ->
        # Cache miss - load from database
        policies = load_policies_for_host(host)
        cache_policies(host, policies)
        Map.get(policies, policy_type, false)
    end
  end

  defp get_cached_policies(host) do
    ensure_cache_table_exists()

    case :ets.lookup(@cache_table, host) do
      [{^host, policies, cached_at}] ->
        if System.monotonic_time(:millisecond) - cached_at < @cache_ttl do
          {:ok, policies}
        else
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_policies(host, policies) do
    ensure_cache_table_exists()
    :ets.insert(@cache_table, {host, policies, System.monotonic_time(:millisecond)})
  end

  defp ensure_cache_table_exists do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:named_table, :public, :set, {:read_concurrency, true}])
    end
  end

  @doc """
  Invalidates the cache for a specific host or all hosts.
  Call this when instance policies are updated.
  """
  def invalidate_cache(host \\ nil) do
    ensure_cache_table_exists()

    if host do
      :ets.delete(@cache_table, host)
    else
      :ets.delete_all_objects(@cache_table)
    end

    :ok
  end

  # Load policies from database for a specific host
  defp load_policies_for_host(host) do
    # Get all instances that could match this host (exact match or wildcard)
    instances = get_matching_instances(host)

    # Merge policies from all matching instances
    Enum.reduce(instances, %{}, fn instance, acc ->
      Instance.policy_fields()
      |> Enum.reduce(acc, fn field, inner_acc ->
        if Map.get(instance, field, false) do
          Map.put(inner_acc, field, true)
        else
          inner_acc
        end
      end)
    end)
    |> merge_config_policies(host)
  end

  # Get instances matching this host (supports wildcards)
  defp get_matching_instances(host) do
    # Get exact match
    exact_query = from(i in Instance, where: i.domain == ^host)

    # Get wildcard matches (domains starting with *.)
    # We need to check each wildcard domain against the host
    wildcard_query =
      from(i in Instance,
        where: like(i.domain, "*.%")
      )

    exact_instances = Repo.all(exact_query)
    wildcard_instances = Repo.all(wildcard_query)

    # Filter wildcards to only those that match
    matching_wildcards =
      Enum.filter(wildcard_instances, fn instance ->
        Instance.matches_domain?(instance, host)
      end)

    exact_instances ++ matching_wildcards
  end

  # Merge with config-based policies as fallback
  defp merge_config_policies(db_policies, host) do
    config = Application.get_env(:elektrine, :mrf_simple, [])

    config_policies =
      [
        {:blocked, :reject},
        {:media_removal, :media_removal},
        {:media_nsfw, :media_nsfw},
        {:federated_timeline_removal, :federated_timeline_removal},
        {:report_removal, :report_removal},
        {:reject_deletes, :reject_deletes},
        {:avatar_removal, :avatar_removal},
        {:banner_removal, :banner_removal}
      ]
      |> Enum.reduce(%{}, fn {policy_field, config_key}, acc ->
        domains = extract_domains(config[config_key] || [])

        if MRF.subdomain_match?(domains, host) do
          Map.put(acc, policy_field, true)
        else
          acc
        end
      end)

    Map.merge(config_policies, db_policies)
  end

  # Config can be list of strings or list of {domain, reason} tuples
  defp extract_domains(list) when is_list(list) do
    Enum.map(list, fn
      {domain, _reason} -> domain
      domain when is_binary(domain) -> domain
    end)
  end

  defp extract_domains(_), do: []

  @impl true
  def describe do
    # Get all instances with policies
    instances =
      from(i in Instance,
        where:
          i.blocked == true or
            i.silenced == true or
            i.media_removal == true or
            i.media_nsfw == true or
            i.federated_timeline_removal == true or
            i.followers_only == true or
            i.report_removal == true or
            i.avatar_removal == true or
            i.banner_removal == true or
            i.reject_deletes == true
      )
      |> Repo.all()

    # Only expose if transparency is enabled
    if Application.get_env(:elektrine, :mrf, [])[:transparency] do
      policy_data =
        Instance.policy_fields()
        |> Enum.map(fn field ->
          domains =
            instances
            |> Enum.filter(fn i -> Map.get(i, field, false) end)
            |> Enum.map(& &1.domain)

          {field, domains}
        end)
        |> Map.new()

      {:ok, %{mrf_simple: policy_data}}
    else
      {:ok, %{}}
    end
  end
end
