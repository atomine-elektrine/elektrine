defmodule ElektrineWeb.ActivityPubController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Cached, as: CachedAccounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Builder
  alias Elektrine.ActivityPub.InboxQueue
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
          actor_data = Builder.build_actor(user)

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
        # Verify the signature actor matches the activity actor
        case conn.assigns[:signature_actor] do
          %{uri: sig_actor_uri} when sig_actor_uri == actor_uri ->
            :ok

          %Elektrine.Accounts.User{} = user ->
            # Local user signature - verify actor matches
            base_url = ElektrineWeb.Endpoint.url()
            expected_uri = "#{base_url}/users/#{user.username}"

            if actor_uri == expected_uri do
              :ok
            else
              {:error, "signature actor mismatch"}
            end

          _ ->
            # Signature valid but actor lookup may have failed - use lightweight check
            validate_signature_header(conn, actor_uri)
        end

      # Signature validation failed - check if it's a Delete we should accept anyway
      conn.assigns[:valid_signature] == false ->
        if activity["type"] == "Delete" do
          {:accept_delete, conn.assigns[:signature_error] || :unknown}
        else
          {:error, conn.assigns[:signature_error] || :invalid_signature}
        end

      # No signature validation done yet (plug may not have run) - use lightweight check
      true ->
        validate_signature_header(conn, actor_uri)
    end
  end

  # Lightweight signature validation - checks signature header exists and keyId matches actor
  # This prevents unsigned requests from being enqueued while avoiding expensive crypto verification
  defp validate_signature_header(conn, actor_uri) do
    case get_req_header(conn, "signature") do
      [signature] when is_binary(signature) and byte_size(signature) > 0 ->
        # Parse signature header to extract keyId
        case parse_signature_key_id(signature) do
          {:ok, key_id} ->
            # Verify keyId belongs to the claimed actor
            # keyId is typically "https://domain/users/name#main-key" or "https://domain/users/name/publickey"
            actor_host = URI.parse(actor_uri).host
            key_host = URI.parse(key_id).host

            if actor_host == key_host do
              :ok
            else
              {:error, "keyId host mismatch"}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, "missing signature header"}
    end
  end

  # Parse keyId from signature header
  defp parse_signature_key_id(signature) do
    # Signature format: keyId="...",algorithm="...",headers="...",signature="..."
    case Regex.run(~r/keyId="([^"]+)"/, signature) do
      [_, key_id] -> {:ok, key_id}
      _ -> {:error, "invalid signature format"}
    end
  end

  # Format error reasons safely for logging (handles tuples, atoms, strings)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  defp get_client_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end

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
    base_url = ActivityPub.instance_url()
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

    base_url = ActivityPub.instance_url()
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
          base_url = ActivityPub.instance_url()
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
          base_url = ActivityPub.instance_url()
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
      case Elektrine.Messaging.get_conversation_by_name(community_name) do
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
    case Elektrine.Messaging.get_conversation_by_name(community_name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Community not found"})

      community ->
        if community.type == "community" do
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
                      handle_community_follow(activity, community, actor_uri)

                    "Undo" ->
                      # Handle Undo Follow (unsubscribe from community)
                      case activity["object"] do
                        %{"type" => "Follow"} ->
                          handle_community_unfollow(activity, community, actor_uri)

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

  # Handle Follow activity for a community
  defp handle_community_follow(activity, community, actor_uri) do
    require Logger

    # Get or fetch the remote actor
    case ActivityPub.get_or_fetch_actor(actor_uri) do
      {:ok, remote_actor} ->
        # Create community actor if it doesn't exist
        {:ok, community_actor} = ActivityPub.get_or_create_community_actor(community.id)

        # For public communities, auto-accept
        if community.is_public do
          # Send Accept activity
          base_url = ActivityPub.instance_url()
          community_slug = String.downcase(community.name) |> String.replace(~r/[^a-z0-9]+/, "-")

          accept_activity = %{
            "@context" => "https://www.w3.org/ns/activitystreams",
            "id" => "#{base_url}/c/#{community_slug}/activities/#{Ecto.UUID.generate()}",
            "type" => "Accept",
            "actor" => community_actor.uri,
            "object" => activity
          }

          # Send Accept to remote actor's inbox
          # Type system expects User struct, but this is a community actor
          Task.start(fn ->
            ActivityPub.Publisher.publish(accept_activity, nil, [remote_actor.inbox_url])
          end)

          Logger.info("Community #{community.name} accepted follow from #{actor_uri}")
          {:ok, :accepted}
        else
          Logger.info(
            "Community #{community.name} received follow request from #{actor_uri} (manual approval required)"
          )

          # Pending follow requests are not persisted yet.
          {:ok, :pending}
        end

      {:error, reason} ->
        Logger.error("Failed to fetch actor #{actor_uri}: #{inspect(reason)}")
        {:error, :actor_fetch_failed}
    end
  end

  # Handle Undo Follow (unsubscribe) for a community
  defp handle_community_unfollow(_activity, community, actor_uri) do
    require Logger
    Logger.info("Community #{community.name} received unfollow from #{actor_uri}")
    # Follower membership is not tracked yet for community actors.
    {:ok, :unfollowed}
  end

  @doc """
  Returns the outbox collection for a community (public posts).
  """
  def community_outbox(conn, %{"name" => community_name} = params) do
    conn = put_resp_header(conn, "content-type", "application/activity+json; charset=utf-8")

    case Elektrine.Messaging.get_conversation_by_name(community_name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Community not found"})

      community ->
        if community.type == "community" && community.is_public do
          # Build community actor URL
          base_url = ActivityPub.instance_url()
          community_slug = String.downcase(community.name) |> String.replace(~r/[^a-z0-9]+/, "-")
          outbox_url = "#{base_url}/c/#{community_slug}/outbox"

          case params["page"] do
            nil ->
              # Return collection metadata
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
              # Return paginated posts
              page_num = String.to_integer(page)
              limit = 20
              offset = (page_num - 1) * limit

              posts =
                Elektrine.Social.get_discussion_posts(community.id,
                  limit: limit,
                  offset: offset,
                  sort_by: "recent"
                )

              # Build Create activities for each post
              items =
                Enum.map(posts, fn post ->
                  # Build Note object
                  note = build_community_note(post, community)

                  # Wrap in Create activity
                  %{
                    "id" => "#{note["id"]}/activity",
                    "type" => "Create",
                    "actor" => "#{base_url}/c/#{community_slug}",
                    "published" => format_datetime(post.inserted_at),
                    "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                    "cc" => ["#{base_url}/c/#{community_slug}/followers"],
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
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "Community not found"})
        end
    end
  end

  @doc """
  Returns the followers collection for a community.
  """
  def community_followers(conn, %{"name" => community_name}) do
    conn = put_resp_header(conn, "content-type", "application/activity+json; charset=utf-8")

    case Elektrine.Messaging.get_conversation_by_name(community_name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Community not found"})

      community ->
        if community.type == "community" && community.is_public do
          base_url = ActivityPub.instance_url()
          community_slug = String.downcase(community.name) |> String.replace(~r/[^a-z0-9]+/, "-")
          followers_url = "#{base_url}/c/#{community_slug}/followers"

          # Get the community actor to count remote followers
          follower_count =
            case ActivityPub.get_community_actor_by_name(community.name) do
              nil -> 0
              actor -> ActivityPub.get_group_follower_count(actor.id)
            end

          # Total includes both local members and remote followers
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
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "Community not found"})
        end
    end
  end

  @doc """
  Returns the moderators collection for a community (Lemmy requirement).
  """
  def community_moderators(conn, %{"name" => community_name}) do
    conn = put_resp_header(conn, "content-type", "application/activity+json; charset=utf-8")

    case Elektrine.Messaging.get_conversation_by_name(community_name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Community not found"})

      community ->
        if community.type == "community" && community.is_public do
          base_url = ActivityPub.instance_url()
          community_slug = String.downcase(community.name) |> String.replace(~r/[^a-z0-9]+/, "-")
          moderators_url = "#{base_url}/c/#{community_slug}/moderators"

          # Get community moderators/admins
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
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "Community not found"})
        end
    end
  end

  # Helper to build a Page object for a community post
  defp build_community_note(post, community) do
    base_url = ActivityPub.instance_url()
    community_slug = String.downcase(community.name) |> String.replace(~r/[^a-z0-9]+/, "-")
    post_id = "#{base_url}/c/#{community_slug}/posts/#{post.id}"
    community_actor_url = "#{base_url}/c/#{community_slug}"

    # Get post author
    author =
      if post.sender do
        "#{base_url}/users/#{post.sender.username}"
      else
        community_actor_url
      end

    # Page objects for top-level posts, Note for comments/replies
    object_type = if post.reply_to_id, do: "Note", else: "Page"

    base_object = %{
      "id" => post_id,
      "type" => object_type,
      "attributedTo" => author,
      "content" => post.content || "",
      "mediaType" => "text/html",
      "published" => format_datetime(post.inserted_at),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [community_actor_url],
      "audience" => community_actor_url,
      "url" => "#{base_url}/communities/#{community.name}/post/#{post.id}",
      "inReplyTo" => nil,
      "sensitive" => post.sensitive || false,
      "context" => "#{base_url}/c/#{community_slug}",
      "commentsEnabled" => !post.locked_at,
      "stickied" => post.is_pinned || false,
      # Could be true for moderator posts
      "distinguished" => false
    }

    # Add optional fields
    base_object =
      if post.edited_at,
        do: Map.put(base_object, "updated", format_datetime(post.edited_at)),
        else: base_object

    base_object =
      if object_type == "Page" && post.title,
        do: Map.put(base_object, "name", post.title),
        else: base_object

    base_object =
      if post.content_warning && post.content_warning != "",
        do: Map.put(base_object, "summary", post.content_warning),
        else: base_object

    base_object
  end

  # Helper to format datetime
  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end
end
