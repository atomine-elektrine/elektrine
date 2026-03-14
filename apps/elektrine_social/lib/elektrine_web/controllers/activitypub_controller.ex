defmodule ElektrineWeb.ActivityPubController do
  use ElektrineSocialWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Cached, as: CachedAccounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Builder
  alias Elektrine.ActivityPub.InboxQueue
  alias Elektrine.Domains
  alias Elektrine.Telemetry.Events

  @doc """
  Returns the actor document for the instance relay.
  """
  def relay_actor(conn, _params) do
    conn = put_resp_header(conn, "content-type", "application/activity+json; charset=utf-8")

    case Elektrine.ActivityPub.Relay.get_or_create_relay_actor() do
      {:ok, relay_actor} ->
        base_url = ActivityPub.instance_url()
        # Use dynamic URL based on current instance domain, not stored URI
        relay_url = "#{base_url}/relay"

        actor_data = %{
          "@context" => [
            "https://www.w3.org/ns/activitystreams",
            "https://w3id.org/security/v1"
          ],
          "id" => relay_url,
          "type" => "Application",
          "preferredUsername" => "relay",
          "name" => relay_actor.display_name || "Elektrine Relay",
          "summary" => relay_actor.summary || "Relay actor for #{ActivityPub.instance_domain()}",
          "inbox" => "#{base_url}/relay/inbox",
          "outbox" => "#{base_url}/relay/outbox",
          "followers" => "#{base_url}/relay/followers",
          "following" => "#{base_url}/relay/following",
          "endpoints" => %{
            "sharedInbox" => "#{base_url}/inbox"
          },
          "publicKey" => %{
            "id" => "#{relay_url}#main-key",
            "owner" => relay_url,
            "publicKeyPem" => relay_actor.public_key
          }
        }

        conn
        |> put_resp_content_type("application/activity+json")
        |> json(actor_data)

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to get relay actor"})
    end
  end

  @doc """
  Returns the actor document for a user.
  """
  def actor(conn, %{"username" => username}) do
    # Override any Accept header issues - always return ActivityPub
    conn = put_resp_header(conn, "content-type", "application/activity+json; charset=utf-8")

    case Accounts.get_user_by_username(username) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        if user.activitypub_enabled do
          # Ensure user has ActivityPub keys (generate if needed)
          {:ok, user} = Elektrine.ActivityPub.KeyManager.ensure_user_has_keys(user)

          # Preload profile to include bio and banner
          user = Elektrine.Repo.preload(user, :profile)

          base_url = activitypub_base_url_for_conn(conn)
          canonical_base_url = ActivityPub.instance_url()

          legacy_base_url =
            case Domains.activitypub_move_from_domain() do
              nil -> nil
              domain -> ActivityPub.instance_url_for_domain(domain)
            end

          legacy_actor_uri =
            if is_binary(legacy_base_url) do
              "#{legacy_base_url}/users/#{user.username}"
            else
              nil
            end

          canonical_actor_uri = "#{canonical_base_url}/users/#{user.username}"

          actor_opts =
            %{base_url: base_url}
            |> maybe_put_actor_moved_to(base_url, legacy_base_url, canonical_actor_uri)
            |> maybe_put_actor_aliases(base_url, canonical_base_url, legacy_actor_uri)

          actor_data = Builder.build_actor(user, actor_opts)

          conn
          |> put_resp_content_type("application/activity+json")
          |> json(actor_data)
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "User not found"})
        end
    end
  end

  @doc """
  Handles incoming activities (Follow, Like, Create, etc.)
  Rate limited and lightweight - just saves to DB without triggering processing.
  """
  def inbox(conn, %{"username" => username} = params) do
    activity = Map.drop(params, ["username"])
    handle_inbox_with_rate_limit(conn, activity, username)
  end

  def inbox(conn, params) do
    activity = Map.drop(params, ["username"])
    handle_inbox_with_rate_limit(conn, activity, nil)
  end

  defp handle_inbox_with_rate_limit(conn, activity, username) do
    require Logger

    # The ActivityPubRateLimit plug runs before signature verification and marks
    # inbox requests it already checked, so we can avoid double counting here.
    if conn.assigns[:activitypub_rate_limit_checked] do
      handle_inbox_activity(conn, activity, username)
    else
      # Get client IP and actor domain for rate limiting
      ip = get_client_ip(conn)

      actor_domain =
        case activity["actor"] do
          actor when is_binary(actor) -> URI.parse(actor).host
          _ -> nil
        end

      rate_limit_start = System.monotonic_time(:millisecond)

      # Check rate limit first (by IP and by domain)
      case Elektrine.ActivityPub.InboxRateLimiter.check_rate_limit(ip, actor_domain) do
        {:error, :rate_limited} ->
          rate_limit_time = System.monotonic_time(:millisecond) - rate_limit_start

          Events.federation(:inbox, :rate_limit, :rate_limited, rate_limit_time, %{
            domain: actor_domain || "unknown"
          })

          conn
          |> put_status(:too_many_requests)
          |> json(%{error: "Rate limited"})

        {:ok, :allowed} ->
          rate_limit_time = System.monotonic_time(:millisecond) - rate_limit_start

          # Log if rate limit check is slow (> 10ms)
          if rate_limit_time > 10 do
            Logger.warning("Slow rate limit check: #{rate_limit_time}ms")
          end

          Events.federation(:inbox, :rate_limit, :ok, rate_limit_time, %{
            domain: actor_domain || "unknown"
          })

          handle_inbox_activity(conn, activity, username)
      end
    end
  end

  defp handle_inbox_activity(conn, activity, username) do
    require Logger
    start_time = System.monotonic_time(:millisecond)

    # Look up target user if specified (using cached version for performance)
    user =
      if username do
        CachedAccounts.get_user_by_username(username)
      else
        nil
      end

    user_lookup_time = System.monotonic_time(:millisecond) - start_time

    # Return 404 for user-specific inbox if user not found
    if username && is_nil(user) do
      total_time = System.monotonic_time(:millisecond) - start_time
      Events.federation(:inbox, :enqueue, :failure, total_time, %{reason: :user_not_found})

      conn
      |> put_status(:not_found)
      |> json(%{error: "User not found"})
    else
      # Get actor URI from activity
      actor_uri = activity["actor"]

      if is_nil(actor_uri) do
        total_time = System.monotonic_time(:millisecond) - start_time
        Events.federation(:inbox, :enqueue, :failure, total_time, %{reason: :missing_actor})

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing actor"})
      else
        # Check signature validation from HTTPSignaturePlug
        # The plug has already validated the signature and assigned :valid_signature
        case check_signature_validation(conn, activity, actor_uri) do
          :ok ->
            enqueue_start = System.monotonic_time(:millisecond)

            # Enqueue to in-memory queue (no DB hit - batched later)
            target_user_id = user && user.id
            result = InboxQueue.enqueue(activity, actor_uri, target_user_id)

            enqueue_time = System.monotonic_time(:millisecond) - enqueue_start
            total_time = System.monotonic_time(:millisecond) - start_time

            # Log timing if slow (> 50ms - should be very fast now)
            if total_time > 50 do
              Logger.warning(
                "Slow inbox: user_lookup=#{user_lookup_time}ms enqueue=#{enqueue_time}ms total=#{total_time}ms"
              )
            end

            # InboxQueue always succeeds (returns {:ok, _})
            _ = result

            Events.federation(:inbox, :enqueue, :success, total_time, %{
              domain: URI.parse(actor_uri).host || "unknown"
            })

            conn
            |> put_status(:accepted)
            |> json(%{})

          {:accept_delete, reason} ->
            # Accept Delete activities from unknown actors to stop Mastodon retries
            Logger.info(
              "Accepting Delete activity despite signature issue: #{format_error(reason)}"
            )

            total_time = System.monotonic_time(:millisecond) - start_time
            Events.federation(:inbox, :signature, :accepted_delete, total_time, %{reason: reason})

            conn
            |> put_status(:accepted)
            |> json(%{})

          {:error, reason} ->
            Logger.warning("Inbox rejected: #{format_error(reason)} from #{actor_uri}")
            total_time = System.monotonic_time(:millisecond) - start_time
            Events.federation(:inbox, :signature, :failure, total_time, %{reason: reason})

            conn
            |> put_status(:unauthorized)
            |> json(%{error: "Invalid or missing signature"})
        end
      end
    end
  end

  # Check signature validation - uses plug-assigned values or falls back to lightweight check
  defp check_signature_validation(conn, activity, actor_uri) do
    cond do
      # Signature was validated by HTTPSignaturePlug
      conn.assigns[:valid_signature] == true ->
        validate_verified_signature_actor(conn, actor_uri)

      # Signature validation failed - check if it's a Delete we should accept anyway
      conn.assigns[:valid_signature] == false ->
        if activity["type"] == "Delete" do
          {:accept_delete, conn.assigns[:signature_error] || :unknown}
        else
          {:error, conn.assigns[:signature_error] || :invalid_signature}
        end

      # Inbox routes must pass through HTTPSignaturePlug before controller dispatch.
      true ->
        {:error, "signature not validated"}
    end
  end

  defp validate_verified_signature_actor(conn, actor_uri) do
    case conn.assigns[:signature_actor] do
      %{uri: sig_actor_uri} ->
        if comparable_uri(sig_actor_uri) == comparable_uri(actor_uri) do
          :ok
        else
          {:error, "signature actor mismatch"}
        end

      %Elektrine.Accounts.User{} = user ->
        case ActivityPub.local_username_from_uri(actor_uri) do
          {:ok, username} when username == user.username -> :ok
          _ -> {:error, "signature actor mismatch"}
        end

      _ ->
        case conn.assigns[:signing_key] do
          %Elektrine.ActivityPub.SigningKey{key_id: key_id} ->
            if comparable_uri(signing_key_actor_uri(key_id)) == comparable_uri(actor_uri) do
              :ok
            else
              {:error, "signature actor mismatch"}
            end

          _ ->
            {:error, "signature actor unavailable"}
        end
    end
  end

  # Format error reasons safely for logging (handles tuples, atoms, strings)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  defp signing_key_actor_uri(key_id) when is_binary(key_id) do
    key_id
    |> String.split("#", parts: 2)
    |> List.first()
  end

  defp signing_key_actor_uri(_), do: nil

  defp comparable_uri(uri) when is_binary(uri) do
    uri
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        case URI.parse(trimmed) do
          %URI{scheme: scheme, host: host} = parsed
          when is_binary(scheme) and is_binary(host) and host != "" ->
            normalized_path =
              parsed.path
              |> Kernel.||("/")
              |> case do
                "/" -> "/"
                path -> String.trim_trailing(path, "/")
              end

            parsed
            |> Map.put(:scheme, String.downcase(scheme))
            |> Map.put(:host, String.downcase(host))
            |> Map.put(:path, normalized_path)
            |> Map.put(:fragment, nil)
            |> URI.to_string()

          _ ->
            trimmed
        end
    end
  end

  defp comparable_uri(_), do: nil

  defp get_client_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end

  defp activitypub_base_url_for_conn(conn) do
    request_host =
      (conn.host || "")
      |> String.trim()
      |> String.downcase()
      |> String.trim_leading("www.")

    move_from_domain = Domains.activitypub_move_from_domain()
    canonical_domain = ActivityPub.instance_domain()

    cond do
      request_host != "" and request_host == move_from_domain ->
        ActivityPub.instance_url_for_domain(request_host)

      request_host != "" and request_host == canonical_domain ->
        ActivityPub.instance_url()

      true ->
        ActivityPub.instance_url()
    end
  end

  defp maybe_put_actor_moved_to(opts, base_url, legacy_base_url, canonical_actor_uri)
       when is_binary(legacy_base_url) and is_binary(canonical_actor_uri) do
    if base_url == legacy_base_url do
      Map.put(opts, :moved_to, canonical_actor_uri)
    else
      opts
    end
  end

  defp maybe_put_actor_moved_to(opts, _base_url, _legacy_base_url, _canonical_actor_uri), do: opts

  defp maybe_put_actor_aliases(opts, base_url, canonical_base_url, legacy_actor_uri)
       when is_binary(legacy_actor_uri) do
    if base_url == canonical_base_url do
      Map.put(opts, :also_known_as, [legacy_actor_uri])
    else
      opts
    end
  end

  defp maybe_put_actor_aliases(opts, _base_url, _canonical_base_url, _legacy_actor_uri), do: opts

  @doc """
  Returns the outbox collection for a user.
  """
  def outbox(conn, %{"username" => username} = params) do
    case Accounts.get_user_by_username(username) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        if user.activitypub_enabled do
          page = params["page"]
          render_outbox(conn, user, page)
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "User not found"})
        end
    end
  end

  defp render_outbox(conn, user, nil) do
    # Return the collection metadata
    base_url = activitypub_base_url_for_conn(conn)
    outbox_url = "#{base_url}/users/#{user.username}/outbox"
    total_items = ActivityPub.count_outbox_activities(user.id)
    page_size = 20
    total_pages = max(1, div(total_items + page_size - 1, page_size))

    collection = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => outbox_url,
      "type" => "OrderedCollection",
      "first" => "#{outbox_url}?page=1",
      "last" => "#{outbox_url}?page=#{total_pages}",
      "totalItems" => total_items
    }

    conn
    |> put_resp_content_type("application/activity+json")
    |> json(collection)
  end

  defp render_outbox(conn, user, page) do
    # Return paginated activities
    page_num = parse_page_number(page)
    page_size = 20
    offset = (page_num - 1) * page_size
    total_items = ActivityPub.count_outbox_activities(user.id)

    activities =
      ActivityPub.list_outbox_activities(user.id,
        limit: page_size,
        offset: offset
      )

    items = Enum.map(activities, & &1.data)

    base_url = activitypub_base_url_for_conn(conn)
    outbox_url = "#{base_url}/users/#{user.username}/outbox"

    collection_page = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{outbox_url}?page=#{page_num}",
      "type" => "OrderedCollectionPage",
      "partOf" => outbox_url,
      "orderedItems" => items
    }

    collection_page =
      if page_num > 1 do
        Map.put(collection_page, "prev", "#{outbox_url}?page=#{page_num - 1}")
      else
        collection_page
      end

    collection_page =
      if offset + length(items) < total_items do
        Map.put(collection_page, "next", "#{outbox_url}?page=#{page_num + 1}")
      else
        collection_page
      end

    conn
    |> put_resp_content_type("application/activity+json")
    |> json(collection_page)
  end

  defp parse_page_number(page) when is_binary(page) do
    case Integer.parse(page) do
      {page_num, ""} when page_num > 0 -> page_num
      _ -> 1
    end
  end

  defp parse_page_number(_), do: 1

  @doc """
  Returns the followers collection for a user.
  """
  def followers(conn, %{"username" => username}) do
    case Accounts.get_user_by_username(username) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        if user.activitypub_enabled do
          base_url = activitypub_base_url_for_conn(conn)
          followers_url = "#{base_url}/users/#{user.username}/followers"

          # Return count but empty items for privacy (standard Mastodon behavior)
          follower_count = Elektrine.Profiles.get_follower_count(user.id)

          collection = %{
            "@context" => "https://www.w3.org/ns/activitystreams",
            "id" => followers_url,
            "type" => "OrderedCollection",
            "totalItems" => follower_count,
            "orderedItems" => []
          }

          conn
          |> put_resp_content_type("application/activity+json")
          |> json(collection)
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "User not found"})
        end
    end
  end

  @doc """
  Returns the following collection for a user.
  """
  def following(conn, %{"username" => username}) do
    case Accounts.get_user_by_username(username) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        if user.activitypub_enabled do
          base_url = activitypub_base_url_for_conn(conn)
          following_url = "#{base_url}/users/#{user.username}/following"

          # Return count but empty items for privacy (standard Mastodon behavior)
          following_count = Elektrine.Profiles.get_following_count(user.id)

          collection = %{
            "@context" => "https://www.w3.org/ns/activitystreams",
            "id" => following_url,
            "type" => "OrderedCollection",
            "totalItems" => following_count,
            "orderedItems" => []
          }

          conn
          |> put_resp_content_type("application/activity+json")
          |> json(collection)
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "User not found"})
        end
    end
  end

  @doc """
  Returns an individual message/object.
  """
  def object(conn, %{"username" => username, "id" => id}) do
    case Accounts.get_user_by_username(username) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})

      user ->
        # Get the message
        case Elektrine.Messaging.get_message(id) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Not found"})

          message ->
            if message.sender_id == user.id do
              object_data = Builder.build_note(message, user)

              conn
              |> put_resp_content_type("application/activity+json")
              |> json(object_data)
            else
              conn
              |> put_status(:not_found)
              |> json(%{error: "Not found"})
            end
        end
    end
  end

  @doc """
  Returns an OrderedCollection of posts with a specific hashtag.
  """
  def hashtag_collection(conn, %{"name" => hashtag_name} = params) do
    # Normalize hashtag name (remove # if present, lowercase)
    normalized_name =
      hashtag_name
      |> String.trim_leading("#")
      |> String.downcase()

    # Get hashtag from database
    case Elektrine.Social.get_hashtag_by_normalized_name(normalized_name) do
      nil ->
        # Return empty collection for non-existent hashtags
        base_url = ActivityPub.instance_url()
        collection_url = "#{base_url}/tags/#{normalized_name}"

        collection = %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => collection_url,
          "type" => "OrderedCollection",
          "totalItems" => 0,
          "orderedItems" => []
        }

        conn
        |> put_resp_content_type("application/activity+json")
        |> json(collection)

      hashtag ->
        # Get posts with this hashtag (public only for federation)
        page = params["page"]
        render_hashtag_collection(conn, hashtag, page)
    end
  end

  defp render_hashtag_collection(conn, hashtag, nil) do
    # First page request - return collection with pagination
    base_url = ActivityPub.instance_url()
    collection_url = "#{base_url}/tags/#{hashtag.normalized_name}"

    # Get total count of public posts with this hashtag
    total_count = Elektrine.Social.count_hashtag_posts(hashtag.id, visibility: "public")

    collection = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => collection_url,
      "type" => "OrderedCollection",
      "totalItems" => total_count,
      "first" => "#{collection_url}?page=1"
    }

    conn
    |> put_resp_content_type("application/activity+json")
    |> json(collection)
  end

  defp render_hashtag_collection(conn, hashtag, page) when is_binary(page) do
    # Paginated page request
    base_url = ActivityPub.instance_url()
    collection_url = "#{base_url}/tags/#{hashtag.normalized_name}"
    page_num = String.to_integer(page)
    limit = 20
    offset = (page_num - 1) * limit

    # Get public posts with this hashtag
    posts =
      Elektrine.Social.list_hashtag_posts(hashtag.id,
        visibility: "public",
        limit: limit,
        offset: offset,
        preload: [:sender, :conversation]
      )

    # Build Note objects for each post
    items =
      Enum.map(posts, fn post ->
        if post.sender do
          Builder.build_note(post, post.sender)
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    collection_page = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{collection_url}?page=#{page}",
      "type" => "OrderedCollectionPage",
      "partOf" => collection_url,
      "orderedItems" => items
    }

    # Add next page if there are more items
    collection_page =
      if length(posts) == limit do
        Map.put(collection_page, "next", "#{collection_url}?page=#{page_num + 1}")
      else
        collection_page
      end

    conn
    |> put_resp_content_type("application/activity+json")
    |> json(collection_page)
  end

  ## Community/Group Actor Endpoints

  @doc """
  Returns the Group actor document for a community.
  Only responds to ActivityPub requests (checks Accept header).
  Browsers requesting HTML will fall through to LiveView.
  """
  def community_actor(conn, %{"name" => community_name}) do
    # Check if this is an ActivityPub request
    accept_header = get_req_header(conn, "accept") |> List.first() || ""

    is_activitypub_request =
      String.contains?(accept_header, "application/activity+json") ||
        String.contains?(accept_header, "application/ld+json")

    if is_activitypub_request do
      # Return ActivityPub JSON
      case ActivityPub.get_community_by_identifier(community_name) do
        nil ->
          conn
          |> put_status(:not_found)
          |> put_resp_content_type("application/activity+json")
          |> json(%{error: "Community not found"})

        community ->
          if community.type == "community" && community.is_public do
            actor_data = Builder.build_group(community)

            conn
            |> put_resp_content_type("application/activity+json")
            |> json(actor_data)
          else
            conn
            |> put_status(:not_found)
            |> put_resp_content_type("application/activity+json")
            |> json(%{error: "Community not found"})
          end
      end
    else
      # Browser request - pass through (will hit LiveView route)
      conn
      |> put_status(404)
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found")
    end
  end

  @doc """
  Handles incoming activities to a community inbox.
  """
  def community_inbox(conn, %{"name" => community_name} = params) do
    case fetch_community_by_identifier(community_name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Community not found"})

      community ->
        if community.type == "community" do
          {:ok, _community_actor} = ActivityPub.get_or_create_community_actor(community.id)
          activity = Map.drop(params, ["name"])
          actor_uri = activity["actor"]

          if is_nil(actor_uri) do
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Missing actor"})
          else
            case check_signature_validation(conn, activity, actor_uri) do
              :ok ->
                # Handle the activity for this community
                _result =
                  case activity["type"] do
                    "Follow" ->
                      Elektrine.ActivityPub.Handlers.FollowHandler.handle(
                        activity,
                        actor_uri,
                        nil
                      )

                    "Undo" ->
                      # Handle Undo Follow (unsubscribe from community)
                      case activity["object"] do
                        %{"type" => "Follow"} = follow_object ->
                          Elektrine.ActivityPub.Handlers.FollowHandler.handle_undo(
                            follow_object,
                            actor_uri
                          )

                        _ ->
                          {:ok, :ignored}
                      end

                    "Create" ->
                      # Handle remote posts to community (if we want to accept external posts)
                      require Logger
                      Logger.info("Community received Create activity from #{actor_uri}")
                      {:ok, :logged}

                    activity_type ->
                      require Logger
                      Logger.info("Community inbox activity: #{activity_type}")
                      {:ok, :logged}
                  end

                conn
                |> put_status(:accepted)
                |> json(%{})

              {:accept_delete, _reason} ->
                conn
                |> put_status(:accepted)
                |> json(%{})

              {:error, _reason} ->
                conn
                |> put_status(:unauthorized)
                |> json(%{error: "Invalid signature"})
            end
          end
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "Community not found"})
        end
    end
  end

  @doc """
  Returns the outbox collection for a community (public posts).
  """
  def community_outbox(conn, %{"name" => community_name} = params) do
    conn = put_resp_header(conn, "content-type", "application/activity+json; charset=utf-8")

    case fetch_public_community(community_name) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Community not found"})

      {:ok, community} ->
        base_url = ActivityPub.instance_url()
        outbox_url = ActivityPub.community_outbox_uri(community.name, base_url)

        case params["page"] do
          nil ->
            post_count = Elektrine.Social.count_discussion_posts(community.id)

            collection = %{
              "@context" => "https://www.w3.org/ns/activitystreams",
              "id" => outbox_url,
              "type" => "OrderedCollection",
              "totalItems" => post_count,
              "first" => "#{outbox_url}?page=1"
            }

            conn
            |> put_resp_content_type("application/activity+json")
            |> json(collection)

          page ->
            page_num = String.to_integer(page)
            limit = 20
            offset = (page_num - 1) * limit

            posts =
              Elektrine.Social.get_discussion_posts(community.id,
                limit: limit,
                offset: offset,
                sort_by: "recent"
              )

            items =
              Enum.map(posts, fn post ->
                note = Builder.build_community_note(post, community)

                %{
                  "id" => "#{note["id"]}/activity",
                  "type" => "Create",
                  "actor" => ActivityPub.community_actor_uri(community.name, base_url),
                  "published" => Builder.format_datetime(post.inserted_at),
                  "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                  "cc" => [ActivityPub.community_followers_uri(community.name, base_url)],
                  "object" => note
                }
              end)

            collection_page = %{
              "@context" => "https://www.w3.org/ns/activitystreams",
              "id" => "#{outbox_url}?page=#{page}",
              "type" => "OrderedCollectionPage",
              "partOf" => outbox_url,
              "orderedItems" => items
            }

            collection_page =
              if length(posts) == limit do
                Map.put(collection_page, "next", "#{outbox_url}?page=#{page_num + 1}")
              else
                collection_page
              end

            conn
            |> put_resp_content_type("application/activity+json")
            |> json(collection_page)
        end
    end
  end

  @doc """
  Returns the followers collection for a community.
  """
  def community_followers(conn, %{"name" => community_name}) do
    conn = put_resp_header(conn, "content-type", "application/activity+json; charset=utf-8")

    case fetch_public_community(community_name) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Community not found"})

      {:ok, community} ->
        base_url = ActivityPub.instance_url()
        followers_url = ActivityPub.community_followers_uri(community.name, base_url)

        follower_count =
          case ActivityPub.get_community_actor_by_name(community.name) do
            nil -> 0
            actor -> ActivityPub.get_group_follower_count(actor.id)
          end

        total_count = (community.member_count || 0) + follower_count

        collection = %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => followers_url,
          "type" => "OrderedCollection",
          "totalItems" => total_count,
          "first" => "#{followers_url}?page=1"
        }

        conn
        |> put_resp_content_type("application/activity+json")
        |> json(collection)
    end
  end

  @doc """
  Returns the moderators collection for a community (Lemmy requirement).
  """
  def community_moderators(conn, %{"name" => community_name}) do
    conn = put_resp_header(conn, "content-type", "application/activity+json; charset=utf-8")

    case fetch_public_community(community_name) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Community not found"})

      {:ok, community} ->
        base_url = ActivityPub.instance_url()
        moderators_url = ActivityPub.community_moderators_uri(community.name, base_url)

        moderator_uris =
          Elektrine.Messaging.get_community_moderators(community.id)
          |> Enum.map(fn member ->
            case member.user do
              nil -> nil
              user -> "#{base_url}/users/#{user.username}"
            end
          end)
          |> Enum.filter(& &1)

        collection = %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => moderators_url,
          "type" => "OrderedCollection",
          "totalItems" => length(moderator_uris),
          "orderedItems" => moderator_uris
        }

        conn
        |> put_resp_content_type("application/activity+json")
        |> json(collection)
    end
  end

  @doc """
  Returns an individual community post object by ActivityPub ID path.
  """
  def community_object(conn, %{"name" => community_name, "id" => message_id}) do
    conn = put_resp_header(conn, "content-type", "application/activity+json; charset=utf-8")

    with {:ok, community} <- fetch_public_community(community_name),
         {:ok, post} <- fetch_public_community_post(community.id, message_id) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> json(Builder.build_community_note(post, community))
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})
    end
  end

  @doc """
  Returns the Create activity wrapping an individual community post object.
  """
  def community_object_activity(conn, %{"name" => community_name, "id" => message_id}) do
    conn = put_resp_header(conn, "content-type", "application/activity+json; charset=utf-8")

    with {:ok, community} <- fetch_public_community(community_name),
         {:ok, post} <- fetch_public_community_post(community.id, message_id) do
      note = Builder.build_community_note(post, community)
      base_url = ActivityPub.instance_url()

      create_activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{note["id"]}/activity",
        "type" => "Create",
        "actor" => ActivityPub.community_actor_uri(community.name, base_url),
        "published" => Builder.format_datetime(post.inserted_at),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [ActivityPub.community_followers_uri(community.name, base_url)],
        "object" => note
      }

      conn
      |> put_resp_content_type("application/activity+json")
      |> json(create_activity)
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})
    end
  end

  defp fetch_public_community(community_name) do
    case fetch_community_by_identifier(community_name) do
      community when not is_nil(community) and community.is_public ->
        {:ok, community}

      _ ->
        {:error, :not_found}
    end
  end

  defp fetch_public_community_post(community_id, message_id) do
    with {id, ""} <- Integer.parse(message_id),
         post when not is_nil(post) <- Elektrine.Messaging.get_message(id),
         true <- post.conversation_id == community_id and is_nil(post.deleted_at),
         true <- post.visibility == "public" do
      {:ok, Elektrine.Repo.preload(post, :sender)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_community_by_identifier(identifier) do
    case ActivityPub.get_community_by_identifier(identifier) do
      %{type: "community"} = community -> community
      _ -> nil
    end
  end
end
