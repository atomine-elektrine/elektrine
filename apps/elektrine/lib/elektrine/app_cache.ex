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
  @admin_ttl :timer.minutes(10)
  @contact_ttl :timer.minutes(15)
  @temp_mailbox_ttl :timer.minutes(2)
  # Increased from 15 min to reduce HTTP/DB load
  @actor_ttl :timer.hours(1)
  # Short TTL for fetched objects - balance freshness vs network load
  @object_ttl :timer.minutes(10)
  # Failed object fetches are cached briefly to avoid hammering unavailable remotes.
  @object_negative_ttl :timer.seconds(90)
  # WebFinger lookups cached longer since they rarely change
  @webfinger_ttl :timer.hours(6)
  # Instance metadata (nodeinfo) cached for a day
  @instance_ttl :timer.hours(24)
  # Passkey challenges - short TTL for security (5 minutes)
  @passkey_challenge_ttl :timer.minutes(5)
  alias Elektrine.Telemetry.Events

  @doc """
  Starts the application cache.
  This should be called from the application supervision tree.
  """
  def start_link(_opts) do
    Cachex.start_link(@cache_name,
      limit: 50_000,
      ttl: @system_ttl
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

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @user_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  @doc """
  Caches user preferences and settings.
  """
  def get_user_preferences(user_id, fetch_fn) do
    key = {:user_preferences, user_id}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @user_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  @doc """
  Caches mailbox settings and configuration.
  """
  def get_mailbox_settings(mailbox_id, fetch_fn) do
    key = {:mailbox_settings, mailbox_id}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @user_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
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

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @search_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  @doc """
  Caches user's recent search queries.
  """
  def get_recent_searches(user_id, fetch_fn) do
    key = {:recent_searches, user_id}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @system_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  # Alias management caching

  @doc """
  Caches email aliases for a user.
  """
  def get_aliases(user_id, fetch_fn) do
    key = {:aliases, user_id}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @contact_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
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

    case fetch_with_telemetry(cache_key, fn _key ->
           {:commit, fetch_fn.(), ttl: @system_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  @doc """
  Caches invite code settings and validation.
  """
  def get_invite_settings(fetch_fn) do
    key = {:invite_settings}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @system_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  # Admin dashboard caching

  @doc """
  Caches admin dashboard statistics.
  """
  def get_admin_stats(stat_type, fetch_fn) do
    key = {:admin_stats, stat_type}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @admin_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  @doc """
  Caches admin dashboard recent activity data.
  """
  def get_admin_recent_activity(activity_type, fetch_fn) do
    key = {:admin_recent, activity_type}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @admin_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  # Temporary mailbox caching

  @doc """
  Caches temporary mailbox validation and metadata.
  """
  def get_temp_mailbox_data(token, fetch_fn) do
    key = {:temp_mailbox, token}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @temp_mailbox_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  # ActivityPub actor caching

  @doc """
  Caches ActivityPub actors by their URI.
  This significantly reduces database load during high-volume inbox processing.
  """
  def get_actor(uri, fetch_fn) do
    key = {:actor, uri}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @actor_ttl}
         end) do
      {:commit, value} -> value
      {:commit, value, _opts} -> value
      {:ok, value} -> value
      error -> error
    end
  end

  @doc """
  Invalidates cached actor data.
  """
  def invalidate_actor(uri) do
    delete_with_telemetry({:actor, uri})
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
               {:commit, {:ok, object}, ttl: @object_ttl}

             {:error, reason} ->
               if negative_cacheable_object_error?(reason) do
                 {:commit, {:error, reason}, ttl: @object_negative_ttl}
               else
                 {:ignore, {:error, reason}}
               end
           end
         end) do
      {:commit, value} -> value
      {:commit, value, _opts} -> value
      {:ok, value} -> value
      {:ignore, value} -> value
      error -> error
    end
  end

  defp negative_cacheable_object_error?(reason)
       when reason in [:not_found, :fetch_failed, :http_error, :invalid_json, :backoff],
       do: true

  defp negative_cacheable_object_error?(_), do: false

  @doc """
  Invalidates cached object data.
  """
  def invalidate_object(uri) do
    delete_with_telemetry({:object, uri})
  end

  # WebFinger caching

  @doc """
  Caches WebFinger lookups by acct.
  WebFinger results rarely change, so we cache them longer.
  """
  def get_webfinger(acct, fetch_fn) do
    key = {:webfinger, acct}

    case fetch_with_telemetry(key, fn _key ->
           case fetch_fn.() do
             {:ok, result} -> {:commit, {:ok, result}, ttl: @webfinger_ttl}
             {:error, reason} -> {:ignore, {:error, reason}}
           end
         end) do
      {:commit, value} -> value
      {:commit, value, _opts} -> value
      {:ok, value} -> value
      {:ignore, value} -> value
      error -> error
    end
  end

  @doc """
  Invalidates cached WebFinger data.
  """
  def invalidate_webfinger(acct) do
    delete_with_telemetry({:webfinger, acct})
  end

  # Instance metadata caching

  @doc """
  Caches instance metadata (nodeinfo) by domain.
  Instance software/version rarely changes.
  """
  def get_instance_metadata(domain, fetch_fn) do
    key = {:instance_metadata, domain}

    case fetch_with_telemetry(key, fn _key ->
           case fetch_fn.() do
             {:ok, metadata} -> {:commit, {:ok, metadata}, ttl: @instance_ttl}
             {:error, reason} -> {:ignore, {:error, reason}}
           end
         end) do
      {:commit, value} -> value
      {:commit, value, _opts} -> value
      {:ok, value} -> value
      {:ignore, value} -> value
      error -> error
    end
  end

  @doc """
  Invalidates cached instance metadata.
  """
  def invalidate_instance_metadata(domain) do
    delete_with_telemetry({:instance_metadata, domain})
  end

  # Platform stats caching (for home page, public pages)

  @doc """
  Caches platform-wide statistics (user count, post count, etc).
  Uses longer TTL since these don't need to be real-time accurate.
  """
  def get_platform_stats(fetch_fn) do
    key = {:platform_stats}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @admin_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
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

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @user_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
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

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @user_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  @doc """
  Caches conversation list for a user.
  """
  def get_conversations(user_id, fetch_fn) do
    key = {:conversations, user_id}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @user_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
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

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @user_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
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

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @user_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  @doc """
  Caches pending friend requests for a user.
  """
  def get_pending_friend_requests(user_id, fetch_fn) do
    key = {:pending_friend_requests, user_id}

    case fetch_with_telemetry(key, fn _key ->
           {:commit, fetch_fn.(), ttl: @user_ttl}
         end) do
      {:commit, value} -> {:ok, value}
      {:commit, value, _opts} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  @doc """
  Invalidates friends cache for a user.
  """
  def invalidate_friends_cache(user_id) do
    delete_with_telemetry({:friends, user_id})
    delete_with_telemetry({:pending_friend_requests, user_id})
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
  Invalidates cache entries for a specific mailbox.
  """
  def invalidate_mailbox_cache(mailbox_id) do
    patterns = [
      {:mailbox_settings, mailbox_id}
    ]

    patterns
    |> Enum.each(&delete_with_telemetry(&1))
  end

  @doc """
  Invalidates system configuration cache.
  """
  def invalidate_system_cache do
    clear_by_pattern({:system_config, :_})
    clear_by_pattern({:invite_settings})
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

  @doc """
  Invalidates temporary mailbox cache.
  """
  def invalidate_temp_mailbox_cache(token) do
    delete_with_telemetry({:temp_mailbox, token})
  end

  # Warming functions

  @doc """
  Warms up cache for a user after login.
  """
  def warm_user_cache(user_id, mailbox_id) do
    Task.start(fn ->
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

  defp fetch_with_telemetry(key, fetch_fn) do
    result = Cachex.fetch(@cache_name, key, fetch_fn)

    fetch_result =
      case result do
        {:ok, _} -> :hit
        {:commit, _} -> :miss
        {:commit, _, _} -> :miss
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
    put_with_telemetry(key, challenge, ttl: @passkey_challenge_ttl)
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
