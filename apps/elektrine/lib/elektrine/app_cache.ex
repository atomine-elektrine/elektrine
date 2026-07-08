defmodule Elektrine.AppCache do
  @moduledoc """
  Centralized caching system for the entire Elektrine application.
  Provides caching for users, mailboxes, admin data, search results,
  and system configurations.
  """

  # Cache names and TTLs
  @cache_name :app_cache
  @user_ttl :timer.minutes(30)
  @system_ttl :timer.hours(1)
  @search_ttl :timer.minutes(5)
  @web_search_ttl :timer.minutes(10)
  @admin_ttl :timer.minutes(10)
  @contact_ttl :timer.minutes(15)
  # Increased from 15 min to reduce HTTP/DB load
  @actor_ttl :timer.hours(1)
  # Short TTL for fetched objects - balance freshness vs network load
  @object_ttl :timer.minutes(10)
  # Failed object fetches are cached briefly to avoid hammering unavailable remotes.
  @object_negative_ttl :timer.seconds(90)
  # ActivityPub ref lookups are hot during inbox processing.
  @activitypub_ref_ttl :timer.minutes(5)
  @activitypub_ref_negative_ttl :timer.seconds(15)
  @activitypub_actor_id_ttl :timer.minutes(10)
  @social_message_ttl :timer.seconds(5)
  @dns_service_config_ttl :timer.minutes(5)
  @site_visit_track_ttl :timer.seconds(60)
  # WebFinger lookups cached longer since they rarely change
  @webfinger_ttl :timer.hours(6)
  @webfinger_negative_ttl :timer.minutes(15)
  @media_proxy_negative_ttl :timer.minutes(15)
  # Passkey challenges - short TTL for security (5 minutes)
  @passkey_challenge_ttl :timer.minutes(5)
  # Portal dashboard counts shown instantly while a fresh load runs
  @portal_dashboard_ttl :timer.minutes(10)
  # Last-known numeric stats per surface, shown instantly while a fresh load runs
  @user_stats_ttl :timer.minutes(10)
  # Domain analytics are expensive aggregate queries; keep them fresh but reusable.
  @domain_analytics_ttl :timer.seconds(60)
  # First page of global (non-personalized) feeds; short TTL to stay fresh
  @global_feed_ttl :timer.minutes(2)
  import Cachex.Spec

  alias Elektrine.Telemetry.Events

  @doc """
  Starts the application cache.
  This should be called from the application supervision tree.
  """
  def start_link(_opts) do
    Cachex.start_link(@cache_name,
      expiration: expiration(default: @system_ttl),
      hooks: [hook(module: Cachex.Limit.Scheduled, args: {50_000, [], []})]
    )
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  # User-related caching

  @doc """
  Caches user profile and settings data.
  """
  def get_user_data(user_id, fetch_fn) do
    key = {:user, user_id}
    fetch_ok(key, @user_ttl, fetch_fn)
  end

  @doc """
  Caches user preferences and settings.
  """
  def get_user_preferences(user_id, fetch_fn) do
    key = {:user_preferences, user_id}
    fetch_ok(key, @user_ttl, fetch_fn)
  end

  @doc """
  Returns the last cached portal dashboard for a user, or nil.

  Used to show last-known overview counts immediately while a fresh
  dashboard load runs in the background (stale-while-revalidate).
  """
  def get_portal_dashboard(user_id) do
    case get_with_telemetry({:portal_dashboard, user_id}) do
      {:ok, %{} = dashboard} -> dashboard
      _ -> nil
    end
  end

  @doc """
  Caches the computed portal dashboard for a user.
  """
  def cache_portal_dashboard(user_id, dashboard) when is_map(dashboard) do
    put_with_telemetry({:portal_dashboard, user_id}, dashboard, expire: @portal_dashboard_ttl)
  end

  @doc """
  Returns the last cached stats map for a named surface and subject
  (e.g. `get_user_stats(:gallery_insights, user_id)`), or nil.

  Used to show last-known numbers immediately while a fresh load runs
  in the background (stale-while-revalidate).
  """
  def get_user_stats(scope, subject_id) when is_atom(scope) do
    case get_with_telemetry({:user_stats, scope, subject_id}) do
      {:ok, %{} = stats} -> stats
      _ -> nil
    end
  end

  @doc """
  Caches the computed stats map for a named surface and subject.
  """
  def cache_user_stats(scope, subject_id, stats) when is_atom(scope) and is_map(stats) do
    put_with_telemetry({:user_stats, scope, subject_id}, stats, expire: @user_stats_ttl)
  end

  @doc """
  Caches the assembled domain analytics payload for a short period.
  """
  def get_domain_analytics(scope, fetch_fn) do
    key = {:domain_analytics, scope}
    fetch_value(key, @domain_analytics_ttl, fetch_fn)
  end

  @doc """
  Returns the cached first page of a global (non-personalized) feed
  (e.g. `get_global_feed({:videos, "discover"})`), or nil.
  """
  def get_global_feed(scope) do
    case get_with_telemetry({:global_feed, scope}) do
      {:ok, [_ | _] = items} -> items
      _ -> nil
    end
  end

  @doc """
  Caches the first page of a global feed. Empty pages are not cached.
  """
  def cache_global_feed(scope, items) when is_list(items) do
    if items == [] do
      {:ok, false}
    else
      put_with_telemetry({:global_feed, scope}, items, expire: @global_feed_ttl)
    end
  end

  @doc """
  Caches mailbox settings and configuration.
  """
  def get_mailbox_settings(mailbox_id, fetch_fn) do
    key = {:mailbox_settings, mailbox_id}
    fetch_ok(key, @user_ttl, fetch_fn)
  end

  # Search caching

  @doc """
  Caches search results with query-specific keys.
  """
  def get_search_results(user_id, query, page, per_page, fetch_fn) do
    # Use SHA256 instead of MD5 for cache key hashing (security best practice)
    query_hash =
      :crypto.hash(:sha256, query) |> Base.encode16(case: :lower) |> String.slice(0, 32)

    key = {:search, user_id, query_hash, page, per_page}
    fetch_ok(key, @search_ttl, fetch_fn)
  end

  @doc """
  Caches external web-search results (shared across users; queries hit paid
  provider APIs).

  The fetch function must return `{:commit, value}` to cache the value or
  `{:ignore, value}` to return it without caching — e.g. degraded results
  that shouldn't stick for the whole TTL.
  """
  def get_web_search_results(key, fetch_fn) do
    case fetch_with_telemetry({:web_search, key}, fn _key ->
           case fetch_fn.() do
             {:commit, value} -> {:commit, value, expire: @web_search_ttl}
             {:ignore, value} -> {:ignore, value}
           end
         end) do
      {:ok, value} -> value
      {:commit, value} -> value
      {:ignore, value} -> value
    end
  end

  @doc """
  Caches user's recent search queries.
  """
  def get_recent_searches(user_id, fetch_fn) do
    key = {:recent_searches, user_id}
    fetch_ok(key, @system_ttl, fetch_fn)
  end

  # Alias management caching

  @doc """
  Caches email aliases for a user.
  """
  def get_aliases(user_id, fetch_fn) do
    key = {:aliases, user_id}
    fetch_ok(key, @contact_ttl, fetch_fn)
  end

  @doc """
  Invalidates cached aliases for a user.
  """
  def invalidate_aliases(user_id) do
    key = {:aliases, user_id}
    delete_with_telemetry(key)
  end

  # System configuration caching

  @doc """
  Caches system-wide configuration settings.
  """
  def get_system_config(key, fetch_fn) do
    cache_key = {:system_config, key}
    fetch_ok(cache_key, @system_ttl, fetch_fn)
  end

  # Admin dashboard caching

  @doc """
  Caches admin dashboard statistics.
  """
  def get_admin_stats(stat_type, fetch_fn) do
    key = {:admin_stats, stat_type}
    fetch_ok(key, @admin_ttl, fetch_fn)
  end

  @doc """
  Caches admin dashboard recent activity data.
  """
  def get_admin_recent_activity(activity_type, fetch_fn) do
    key = {:admin_recent, activity_type}
    fetch_ok(key, @admin_ttl, fetch_fn)
  end

  # ActivityPub actor caching

  @doc """
  Caches ActivityPub actors by their URI.
  This significantly reduces database load during high-volume inbox processing.
  """
  def get_actor(uri, fetch_fn) do
    key = {:actor, uri}
    fetch_value(key, @actor_ttl, fetch_fn)
  end

  @doc """
  Caches ActivityPub actors by database ID for hot broadcast/projection paths.
  """
  def get_activitypub_actor_by_id(actor_id, fetch_fn) when is_integer(actor_id) do
    key = {:activitypub_actor_id, actor_id}
    fetch_value(key, @activitypub_actor_id_ttl, fetch_fn)
  end

  # ActivityPub object caching

  @doc """
  Caches ActivityPub objects by their URI.
  This reduces HTTP requests when fetching the same object multiple times.
  """
  def get_object(uri, fetch_fn) do
    key = {:object, uri}

    case fetch_with_telemetry(key, fn _key ->
           case fetch_fn.() do
             {:ok, object} ->
               {:commit, {:ok, object}, expire: @object_ttl}

             {:error, reason} ->
               if negative_cacheable_object_error?(reason) do
                 {:commit, {:error, reason}, expire: @object_negative_ttl}
               else
                 {:ignore, {:error, reason}}
               end
           end
         end) do
      {:commit, value} -> value
      {:ok, value} -> value
      {:ignore, value} -> value
      error -> error
    end
  end

  defp negative_cacheable_object_error?(reason)
       when reason in [
              :not_found,
              :fetch_failed,
              :http_error,
              :invalid_json,
              :backoff,
              :unauthorized_fetch
            ],
       do: true

  defp negative_cacheable_object_error?(_), do: false

  @doc """
  Invalidates cached object data.
  """
  def invalidate_object(uri) do
    delete_with_telemetry({:object, uri})
  end

  @doc """
  Caches message lookups by normalized ActivityPub ref.
  Missing refs are cached briefly to avoid repeated expensive misses during inbox storms.
  """
  def get_activitypub_message_ref(ref, fetch_fn) when is_binary(ref) do
    key = {:activitypub_ref, normalize_activitypub_ref(ref)}

    case fetch_with_telemetry(key, fn _key ->
           case fetch_fn.() do
             nil -> {:commit, :not_found, expire: @activitypub_ref_negative_ttl}
             value -> {:commit, value, expire: @activitypub_ref_ttl}
           end
         end) do
      {:commit, :not_found} -> nil
      {:ok, :not_found} -> nil
      {:commit, value} -> value
      {:ok, value} -> value
      _ -> nil
    end
  end

  @doc """
  Invalidates a cached ActivityPub ref lookup.
  """
  def invalidate_activitypub_message_ref(ref) when is_binary(ref) do
    delete_with_telemetry({:activitypub_ref, normalize_activitypub_ref(ref)})
  end

  @doc """
  Caches social message primary-key lookups briefly to absorb repeated UI/broadcast reads.
  """
  def get_social_message(message_id, fetch_fn) when is_integer(message_id) do
    key = {:social_message, message_id}
    fetch_value(key, @social_message_ttl, fetch_fn)
  end

  def invalidate_social_message(message_id) when is_integer(message_id) do
    delete_with_telemetry({:social_message, message_id})
  end

  @doc """
  Caches DNS service configs per zone. Managed service writes explicitly invalidate this.
  """
  def get_dns_service_configs(zone_id, fetch_fn) when is_integer(zone_id) do
    key = {:dns_service_configs, zone_id}
    fetch_value(key, @dns_service_config_ttl, fetch_fn)
  end

  def invalidate_dns_service_configs(zone_id) when is_integer(zone_id) do
    delete_with_telemetry({:dns_service_configs, zone_id})
  end

  @doc """
  Returns true once per short tracking window for a site/page/session tuple.
  """
  def allow_site_visit_tracking?(scope, session_id, request_host, request_path, status)
      when is_binary(session_id) and is_binary(request_path) do
    key = {:site_visit_seen, scope, session_id, request_host, request_path, status}

    case get_with_telemetry(key) do
      {:ok, nil} ->
        _ = put_with_telemetry(key, true, expire: @site_visit_track_ttl)
        true

      {:ok, _} ->
        false

      _ ->
        true
    end
  end

  def allow_site_visit_tracking?(_scope, _session_id, _request_host, _request_path, _status),
    do: true

  # WebFinger caching

  @doc """
  Caches WebFinger lookups by acct.
  WebFinger results rarely change, so we cache them longer.
  """
  def get_webfinger(acct, fetch_fn) do
    key = {:webfinger, acct}

    case fetch_with_telemetry(key, fn _key ->
           case fetch_fn.() do
             {:ok, result} ->
               {:commit, {:ok, result}, expire: @webfinger_ttl}

             {:error, :not_found} ->
               {:commit, {:error, :not_found}, expire: @webfinger_negative_ttl}

             {:error, reason} ->
               {:ignore, {:error, reason}}
           end
         end) do
      {:commit, value} -> value
      {:ok, value} -> value
      {:ignore, value} -> value
      error -> error
    end
  end

  @doc """
  Returns true if a proxied media URL recently failed upstream fetching.
  """
  def media_proxy_failed?(url) when is_binary(url) do
    case get_with_telemetry({:media_proxy_failed, url}) do
      {:ok, nil} -> false
      {:ok, _reason} -> true
      _ -> false
    end
  end

  def media_proxy_failed?(_url), do: false

  @doc """
  Temporarily records a failed proxied media URL to avoid hammering remote hosts.
  """
  def mark_media_proxy_failed(url, reason) when is_binary(url) do
    put_with_telemetry({:media_proxy_failed, url}, reason, expire: @media_proxy_negative_ttl)
  end

  def mark_media_proxy_failed(_url, _reason), do: {:ok, false}

  @doc """
  Clears cached media proxy failure state after a successful fetch or admin invalidation.
  """
  def invalidate_media_proxy_failure(url) when is_binary(url) do
    delete_with_telemetry({:media_proxy_failed, url})
  end

  def invalidate_media_proxy_failure(_url), do: {:ok, false}

  @doc """
  Returns true if an admin has temporarily banned a media proxy URL.
  """
  def media_proxy_banned?(url) when is_binary(url) do
    case get_with_telemetry({:media_proxy_banned, url}) do
      {:ok, nil} -> false
      {:ok, _metadata} -> true
      _ -> false
    end
  end

  def media_proxy_banned?(_url), do: false

  @doc """
  Adds a runtime media proxy ban. Persistent policy still belongs in config blocklists.
  """
  def ban_media_proxy_url(url, reason \\ :admin)

  def ban_media_proxy_url(url, reason) when is_binary(url) do
    put_with_telemetry(
      {:media_proxy_banned, url},
      %{reason: inspect(reason), inserted_at: DateTime.utc_now()},
      expire: :timer.hours(24)
    )
  end

  def ban_media_proxy_url(_url, _reason), do: {:ok, false}

  @doc """
  Removes a runtime media proxy ban.
  """
  def unban_media_proxy_url(url) when is_binary(url) do
    delete_with_telemetry({:media_proxy_banned, url})
  end

  def unban_media_proxy_url(_url), do: {:ok, false}

  @doc """
  Lists recent media proxy failure cache entries.
  """
  def list_media_proxy_failures(limit \\ 100) do
    list_media_proxy_entries(:media_proxy_failed, limit)
  end

  @doc """
  Lists runtime media proxy bans.
  """
  def list_media_proxy_bans(limit \\ 100) do
    list_media_proxy_entries(:media_proxy_banned, limit)
  end

  # Platform stats caching (for home page, public pages)

  @doc """
  Caches platform-wide statistics (user count, post count, etc).
  Uses longer TTL since these don't need to be real-time accurate.
  """
  def get_platform_stats(fetch_fn) do
    key = {:platform_stats}
    fetch_ok(key, @admin_ttl, fetch_fn)
  end

  @doc """
  Invalidates platform stats cache.
  """
  def invalidate_platform_stats do
    delete_with_telemetry({:platform_stats})
  end

  # Storage caching

  @doc """
  Caches storage info for a user.
  """
  def get_storage_info(user_id, fetch_fn) do
    key = {:storage_info, user_id}
    fetch_ok(key, @user_ttl, fetch_fn)
  end

  @doc """
  Invalidates storage cache for a user.
  """
  def invalidate_storage_cache(user_id) do
    delete_with_telemetry({:storage_info, user_id})
  end

  # Chat/Messaging caching

  @doc """
  Caches chat unread count for a user.
  """
  def get_chat_unread_count(user_id, fetch_fn) do
    key = {:chat_unread, user_id}
    fetch_ok(key, @user_ttl, fetch_fn)
  end

  @doc """
  Caches conversation list for a user.
  """
  def get_conversations(user_id, fetch_fn) do
    key = {:conversations, user_id}
    fetch_ok(key, @user_ttl, fetch_fn)
  end

  @doc """
  Invalidates chat cache for a user.
  """
  def invalidate_chat_cache(user_id) do
    delete_with_telemetry({:chat_unread, user_id})
    delete_with_telemetry({:conversations, user_id})
  end

  # Notification caching

  @doc """
  Caches notification unread count for a user.
  """
  def get_notification_unread_count(user_id, fetch_fn) do
    key = {:notification_unread, user_id}
    fetch_ok(key, @user_ttl, fetch_fn)
  end

  @doc """
  Invalidates notification cache for a user.
  """
  def invalidate_notification_cache(user_id) do
    delete_with_telemetry({:notification_unread, user_id})
  end

  # Friends caching

  @doc """
  Caches friends list for a user.
  """
  def get_friends(user_id, fetch_fn) do
    key = {:friends, user_id}
    fetch_ok(key, @user_ttl, fetch_fn)
  end

  @doc """
  Caches pending friend requests for a user.
  """
  def get_pending_friend_requests(user_id, fetch_fn) do
    key = {:pending_friend_requests, user_id}
    fetch_ok(key, @user_ttl, fetch_fn)
  end

  @doc """
  Invalidates friends cache for a user.
  """
  def invalidate_friends_cache(user_id) do
    delete_with_telemetry({:friends, user_id})
    delete_with_telemetry({:pending_friend_requests, user_id})
  end

  @doc """
  Caches remote user/community count snapshots for profile pages.
  """
  def get_remote_user_counts(actor_id, fetch_fn) do
    key = {:remote_user_counts, actor_id}
    fetch_ok(key, @contact_ttl, fetch_fn)
  end

  def put_remote_user_counts(actor_id, counts) do
    put_with_telemetry({:remote_user_counts, actor_id}, counts, expire: @contact_ttl)
  end

  def get_remote_user_community_stats(actor_id, fetch_fn) do
    key = {:remote_user_community_stats, actor_id}
    fetch_ok(key, @contact_ttl, fetch_fn)
  end

  def put_remote_user_community_stats(actor_id, stats) do
    put_with_telemetry({:remote_user_community_stats, actor_id}, stats, expire: @contact_ttl)
  end

  # Cache invalidation functions

  @doc """
  Invalidates all cache entries for a specific user.
  """
  def invalidate_user_cache(user_id) do
    patterns = [
      {:user, user_id},
      {:user_preferences, user_id},
      {:recent_searches, user_id},
      {:aliases, user_id},
      {:chat_unread, user_id},
      {:conversations, user_id},
      {:notification_unread, user_id},
      {:storage_info, user_id}
    ]

    patterns
    |> Enum.each(&delete_with_telemetry(&1))

    # Also invalidate search results for this user
    clear_user_searches(user_id)
  end

  @doc """
  Invalidates system configuration cache.
  """
  def invalidate_system_cache do
    clear_by_pattern({:system_config, :_})
  end

  @doc """
  Invalidates admin dashboard cache.
  """
  def invalidate_admin_cache do
    clear_by_pattern({:admin_stats, :_})
    clear_by_pattern({:admin_recent, :_})
  end

  @doc """
  Invalidates search results for a user.
  """
  def invalidate_search_cache(user_id) do
    clear_user_searches(user_id)
    delete_with_telemetry({:recent_searches, user_id})
  end

  # Warming functions

  @doc """
  Warms up cache for a user after login.
  """
  def warm_user_cache(user_id, mailbox_id) do
    Elektrine.Async.start(fn ->
      # Warm user data
      try do
        user = Elektrine.Accounts.get_user!(user_id)
        get_user_data(user_id, fn -> user end)
      rescue
        _ -> :ok
      end

      # Warm mailbox settings
      try do
        mailbox = Elektrine.Email.get_mailbox_internal(mailbox_id)
        get_mailbox_settings(mailbox_id, fn -> mailbox end)
      rescue
        _ -> :ok
      end
    end)
  end

  @doc """
  Gets cache statistics for monitoring.
  """
  def stats do
    Cachex.stats(@cache_name)
  end

  @doc """
  Clears all application cache entries.
  """
  def clear_all do
    clear_with_telemetry()
  end

  @doc """
  Clears cache entries matching a pattern.
  """
  def clear_by_pattern(pattern) do
    {:ok, keys} = keys_with_telemetry()

    keys
    |> Enum.filter(&matches_pattern?(&1, pattern))
    |> Enum.each(&delete_with_telemetry(&1))
  end

  # Private helper functions

  defp fetch_ok(key, ttl, fetch_fn) do
    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), expire: ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  defp fetch_value(key, ttl, fetch_fn) do
    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), expire: ttl}
         end) do
      {:commit, value} -> value
      {:ok, value} -> value
      error -> error
    end
  end

  defp clear_user_searches(user_id) do
    {:ok, keys} = keys_with_telemetry()

    keys
    |> Enum.filter(fn
      {:search, ^user_id, _, _, _} -> true
      _ -> false
    end)
    |> Enum.each(&delete_with_telemetry(&1))
  end

  defp matches_pattern?(key, pattern) when is_tuple(key) and is_tuple(pattern) do
    key_list = Tuple.to_list(key)
    pattern_list = Tuple.to_list(pattern)

    length(key_list) == length(pattern_list) and
      Enum.zip(key_list, pattern_list)
      |> Enum.all?(fn
        {_key_elem, :_} -> true
        {key_elem, pattern_elem} -> key_elem == pattern_elem
      end)
  end

  defp matches_pattern?(_, _), do: false

  defp list_media_proxy_entries(prefix, limit) do
    {:ok, keys} = keys_with_telemetry()

    keys
    |> Enum.filter(fn
      {^prefix, url} when is_binary(url) -> true
      _ -> false
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {^prefix, url} = key ->
      value =
        case get_with_telemetry(key) do
          {:ok, metadata} -> metadata
          _ -> nil
        end

      %{url: url, metadata: value}
    end)
  end

  # Cachex 4 executes `Cachex.fetch/3` fallbacks inside its Courier process.
  # Our fallbacks read from the database, and several callers invoke them
  # while already holding a checked-out DB connection inside a transaction
  # (for example federation ingress applying an event). That deadlocks: the
  # caller blocks on the Courier while the Courier's fallback blocks waiting
  # for a database connection. Run the fallback in the calling process
  # instead (Cachex 3 semantics), trading cross-process fetch coalescing for
  # deadlock safety.
  defp fetch_with_telemetry(key, fetch_fn) do
    result =
      case Cachex.get(@cache_name, key) do
        {:ok, value} when not is_nil(value) ->
          {:ok, value}

        _miss_or_error ->
          case fetch_fn.(key) do
            {:commit, value} = commit ->
              _ = Cachex.put(@cache_name, key, value)
              commit

            {:commit, value, opts} ->
              _ = Cachex.put(@cache_name, key, value, Keyword.take(List.wrap(opts), [:expire]))
              # Match Cachex.fetch/3, which strips commit options from the
              # returned tuple.
              {:commit, value}

            {:ignore, _value} = ignore ->
              ignore

            other ->
              other
          end
      end

    fetch_result =
      case result do
        {:ok, _} -> :hit
        {:commit, _} -> :miss
        {:ignore, _} -> :ignored
        _ -> :error
      end

    emit_cache(:fetch, fetch_result, key)
    result
  end

  defp get_with_telemetry(key) do
    result = Cachex.get(@cache_name, key)

    get_result =
      case result do
        {:ok, nil} -> :miss
        {:ok, _value} -> :hit
        _ -> :error
      end

    emit_cache(:get, get_result, key)
    result
  end

  defp put_with_telemetry(key, value, opts) do
    result = Cachex.put(@cache_name, key, value, opts)
    emit_cache(:put, cachex_result(result), key)
    result
  end

  defp delete_with_telemetry(key) do
    result = Cachex.del(@cache_name, key)
    emit_cache(:delete, cachex_result(result), key)
    result
  end

  defp clear_with_telemetry do
    result = Cachex.clear(@cache_name)
    emit_cache(:clear, cachex_result(result), :all)
    result
  end

  defp keys_with_telemetry do
    result = Cachex.keys(@cache_name)
    emit_cache(:keys, cachex_result(result), :all)
    result
  end

  defp cachex_result({:ok, _}), do: :ok
  defp cachex_result(:ok), do: :ok
  defp cachex_result(_), do: :error

  defp normalize_activitypub_ref(ref) do
    ref
    |> String.trim()
    |> String.split("#", parts: 2)
    |> hd()
    |> String.split("?", parts: 2)
    |> hd()
    |> String.trim_trailing("/")
  end

  defp emit_cache(operation, result, key) do
    Events.cache(:app_cache, operation, result, %{scope: cache_scope(key)})
  end

  defp cache_scope({scope, _}) when is_atom(scope), do: scope
  defp cache_scope({scope, _, _}) when is_atom(scope), do: scope
  defp cache_scope({scope, _, _, _}) when is_atom(scope), do: scope
  defp cache_scope({scope, _, _, _, _}) when is_atom(scope), do: scope
  defp cache_scope(_), do: :other

  # =============================================================================
  # Passkey Challenge Caching
  # =============================================================================

  @doc """
  Store a passkey authentication challenge.
  The challenge is keyed by its bytes for later retrieval.
  """
  def put_passkey_challenge(challenge_bytes, challenge) when is_binary(challenge_bytes) do
    key = {:passkey_challenge, challenge_bytes}
    put_with_telemetry(key, challenge, expire: @passkey_challenge_ttl)
  end

  @doc """
  Retrieve a passkey authentication challenge by its bytes.
  Returns {:ok, challenge} or {:ok, nil} if not found/expired.
  """
  def get_passkey_challenge(challenge_bytes) when is_binary(challenge_bytes) do
    key = {:passkey_challenge, challenge_bytes}

    case get_with_telemetry(key) do
      {:ok, challenge} when not is_nil(challenge) ->
        # Delete after retrieval to prevent replay attacks
        delete_with_telemetry(key)
        {:ok, challenge}

      _ ->
        {:ok, nil}
    end
  end
end
