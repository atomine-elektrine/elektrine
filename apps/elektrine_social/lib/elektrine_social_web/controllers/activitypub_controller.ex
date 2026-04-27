defmodule ElektrineSocialWeb.ActivityPubController do
  use ElektrineSocialWeb, :controller

  require Logger

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Cached, as: CachedAccounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Builder
  alias Elektrine.ActivityPub.InboxQueue
  alias Elektrine.ActivityPub.ObjectValidator
  alias Elektrine.Domains
  alias Elektrine.Messaging
  alias Elektrine.Profiles
  alias Elektrine.Social.Message
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
  def actor(conn, %{"username" => identifier}) do
    # Override any Accept header issues - always return ActivityPub
    conn = put_resp_header(conn, "content-type", "application/activity+json; charset=utf-8")
    requested_identifier = ActivityPub.actor_identifier(identifier)

    case Accounts.get_user_by_activitypub_identifier(requested_identifier) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        if user.activitypub_enabled do
          # Ensure user has ActivityPub keys (generate if needed)
          {:ok, user} = Elektrine.ActivityPub.KeyManager.ensure_user_has_keys(user)

          # Preload profile links so actor attachments include exported profile fields.
          user = Elektrine.Repo.preload(user, profile: :links)

          base_url = activitypub_base_url_for_conn(conn)
          canonical_base_url = ActivityPub.instance_url()

          legacy_base_url =
            case Domains.activitypub_move_from_domain() do
              nil -> nil
              domain -> ActivityPub.instance_url_for_domain(domain)
            end

          actor_opts =
            actor_request_opts(
              user,
              requested_identifier,
              base_url,
              canonical_base_url,
              legacy_base_url
            )

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

    # Older requests may already be checked by the pre-controller plug.
    if conn.assigns[:activitypub_rate_limit_checked] do
      handle_inbox_activity(conn, activity, username)
    else
      # Get client IP and actor domain for rate limiting
      ip = get_client_ip(conn)

      actor_domain = verified_signature_actor_domain(conn)

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
    start_time = System.monotonic_time(:millisecond)

    # Look up target user if specified (using cached version for performance)
    user =
      if username do
        CachedAccounts.get_user_by_activitypub_identifier(username)
      else
        nil
      end

    user_lookup_time = System.monotonic_time(:millisecond) - start_time

    # Return 404 for user-specific inbox if the user is missing or not AP-enabled.
    if username && (is_nil(user) || user.activitypub_enabled != true) do
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
            case validate_incoming_activity(activity, actor_uri) do
              {:ok, validated_activity} ->
                case validate_inbound_delivery_policy(validated_activity, actor_uri, user, nil) do
                  :ok ->
                    enqueue_start = System.monotonic_time(:millisecond)

                    # Enqueue to in-memory queue (no DB hit - batched later)
                    target_user_id = user && user.id
                    result = InboxQueue.enqueue(validated_activity, actor_uri, target_user_id)

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
                      domain: actor_domain(actor_uri)
                    })

                    conn
                    |> put_status(:accepted)
                    |> json(%{})

                  {:error, reason} ->
                    Logger.info(
                      "Dropping inbox activity #{inspect(validated_activity["id"])} from #{format_actor_ref(actor_uri)}: #{inspect(reason)}"
                    )

                    conn
                    |> put_status(:accepted)
                    |> json(%{})
                end

              {:error, :invalid_activity} ->
                total_time = System.monotonic_time(:millisecond) - start_time

                Events.federation(:inbox, :enqueue, :failure, total_time, %{
                  reason: :invalid_activity
                })

                conn
                |> put_status(:bad_request)
                |> json(%{error: "Invalid activity"})
            end

          {:error, reason} ->
            Logger.warning(
              "Inbox rejected: #{format_error(reason)} from #{format_actor_ref(actor_uri)}"
            )

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
  defp check_signature_validation(conn, _activity, actor_uri) do
    cond do
      # Signature was validated by HTTPSignaturePlug
      conn.assigns[:valid_signature] == true ->
        validate_verified_signature_actor(conn, actor_uri)

      # Signature validation failed
      conn.assigns[:valid_signature] == false ->
        {:error, conn.assigns[:signature_error] || :invalid_signature}

      # Inbox routes must pass through HTTPSignaturePlug before controller dispatch.
      true ->
        {:error, "signature not validated"}
    end
  end

  defp validate_verified_signature_actor(conn, actor_uri) do
    case conn.assigns[:signature_actor] do
      %{uri: sig_actor_uri} = sig_actor ->
        if signature_actor_matches?(sig_actor_uri, actor_uri, sig_actor) do
          :ok
        else
          {:error,
           {:signature_actor_mismatch,
            %{
              actor: actor_uri,
              signature_actor: sig_actor_uri,
              signature_actor_username: Map.get(sig_actor, :username),
              key_id: signing_key_id(conn.assigns[:signing_key])
            }}}
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
              {:error,
               {:signature_actor_mismatch,
                %{
                  actor: actor_uri,
                  signature_actor: signing_key_actor_uri(key_id),
                  key_id: key_id
                }}}
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

  defp format_actor_ref(actor_uri) when is_binary(actor_uri), do: actor_uri
  defp format_actor_ref(actor_uri), do: inspect(actor_uri)

  defp actor_domain(actor_uri) when is_binary(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "unknown"
    end
  end

  defp actor_domain(_), do: "unknown"

  defp signing_key_actor_uri(key_id) when is_binary(key_id) do
    key_id
    |> String.split("#", parts: 2)
    |> List.first()
  end

  defp signing_key_actor_uri(_), do: nil

  defp verified_signature_actor_domain(conn) do
    case conn.assigns[:signature_actor] do
      %{uri: uri} when is_binary(uri) -> actor_domain(uri)
      %Elektrine.Accounts.User{} -> ActivityPub.instance_url() |> actor_domain()
      _ -> nil
    end
  end

  defp signing_key_id(%Elektrine.ActivityPub.SigningKey{key_id: key_id}), do: key_id
  defp signing_key_id(_), do: nil

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
              |> normalize_activitypub_actor_path()
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

  defp signature_actor_matches?(sig_actor_uri, actor_uri, sig_actor) do
    comparable_uri(sig_actor_uri) == comparable_uri(actor_uri) ||
      signature_actor_username_alias_match?(sig_actor_uri, actor_uri, sig_actor) ||
      signature_actor_moved_to_match?(actor_uri, sig_actor) ||
      signature_actor_reciprocal_alias_match?(sig_actor_uri, actor_uri, sig_actor)
  end

  defp signature_actor_moved_to_match?(actor_uri, %{metadata: metadata})
       when is_binary(actor_uri) do
    normalized_actor_uri = comparable_uri(actor_uri)

    metadata
    |> extract_uri_candidates("movedTo")
    |> Enum.map(&comparable_uri/1)
    |> Enum.member?(normalized_actor_uri)
  end

  defp signature_actor_moved_to_match?(_, _), do: false

  defp signature_actor_username_alias_match?(sig_actor_uri, actor_uri, sig_actor)
       when is_binary(sig_actor_uri) and is_binary(actor_uri) do
    with %URI{host: sig_host} <- URI.parse(sig_actor_uri),
         %URI{host: actor_host} <- URI.parse(actor_uri),
         true <- is_binary(sig_host) and is_binary(actor_host),
         true <- String.downcase(sig_host) == String.downcase(actor_host),
         username when is_binary(username) and username != "" <- Map.get(sig_actor, :username),
         actor_username when is_binary(actor_username) and actor_username != "" <-
           Elektrine.ActivityPub.Helpers.extract_username_from_uri(actor_uri) do
      String.downcase(username) == String.downcase(actor_username)
    else
      _ -> false
    end
  end

  defp signature_actor_username_alias_match?(_, _, _), do: false

  defp signature_actor_reciprocal_alias_match?(sig_actor_uri, actor_uri, sig_actor)
       when is_binary(sig_actor_uri) and is_binary(actor_uri) and is_map(sig_actor) do
    normalized_actor_uri = comparable_uri(actor_uri)
    normalized_sig_actor_uri = comparable_uri(sig_actor_uri)

    sig_alias_uris = actor_alias_uris(sig_actor) |> Enum.map(&comparable_uri/1)

    if normalized_actor_uri in sig_alias_uris do
      case ActivityPub.get_or_fetch_actor(actor_uri) do
        {:ok, claimed_actor} ->
          claimed_alias_uris = actor_alias_uris(claimed_actor) |> Enum.map(&comparable_uri/1)
          normalized_sig_actor_uri in claimed_alias_uris

        _ ->
          false
      end
    else
      false
    end
  end

  defp signature_actor_reciprocal_alias_match?(_, _, _), do: false

  defp actor_alias_uris(%{metadata: metadata}) do
    extract_uri_candidates(metadata, "movedTo") ++ extract_uri_candidates(metadata, "alsoKnownAs")
  end

  defp actor_alias_uris(_), do: []

  defp extract_uri_candidates(metadata, field) when is_map(metadata) do
    metadata
    |> Map.get(field)
    |> expand_uri_candidates()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_uri_candidates(_metadata, _field), do: []

  defp expand_uri_candidates(value) when is_binary(value), do: [value]

  defp expand_uri_candidates(values) when is_list(values),
    do: Enum.flat_map(values, &expand_uri_candidates/1)

  defp expand_uri_candidates(%{"id" => id}) when is_binary(id), do: [id]
  defp expand_uri_candidates(%{"href" => href}) when is_binary(href), do: [href]
  defp expand_uri_candidates(%{"url" => url}) when is_binary(url), do: [url]
  defp expand_uri_candidates(_), do: []

  defp normalize_activitypub_actor_path(path) when is_binary(path) do
    case Regex.run(~r|^/@([^/?#]+)$|, path) do
      [_, username] -> "/users/#{username}"
      _ -> path
    end
  end

  defp normalize_activitypub_actor_path(_), do: "/"

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

  defp actor_request_opts(
         user,
         requested_identifier,
         base_url,
         canonical_base_url,
         legacy_base_url
       ) do
    canonical_actor_uri = ActivityPub.actor_uri(user, canonical_base_url)
    requested_actor_uri = ActivityPub.actor_uri(requested_identifier, base_url)

    if requested_actor_uri != canonical_actor_uri do
      %{
        base_url: base_url,
        actor_identifier: requested_identifier,
        moved_to: canonical_actor_uri
      }
    else
      aliases = actor_alias_uris(user, canonical_base_url, legacy_base_url)

      if aliases == [] do
        %{base_url: base_url}
      else
        %{base_url: base_url, also_known_as: aliases}
      end
    end
  end

  defp actor_alias_uris(user, canonical_base_url, legacy_base_url) do
    canonical_actor_uri = ActivityPub.actor_uri(user, canonical_base_url)

    [
      username_alias_uri(user, canonical_base_url),
      legacy_actor_uri(user, legacy_base_url),
      legacy_username_alias_uri(user, legacy_base_url)
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == canonical_actor_uri))
    |> Enum.uniq()
  end

  defp username_alias_uri(user, base_url) do
    canonical_identifier = ActivityPub.actor_identifier(user)

    if canonical_identifier == user.username do
      nil
    else
      ActivityPub.actor_uri_by_username(user, base_url)
    end
  end

  defp legacy_actor_uri(user, legacy_base_url) when is_binary(legacy_base_url) do
    ActivityPub.actor_uri(user, legacy_base_url)
  end

  defp legacy_actor_uri(_user, _legacy_base_url), do: nil

  defp legacy_username_alias_uri(user, legacy_base_url) when is_binary(legacy_base_url) do
    username_alias_uri(user, legacy_base_url)
  end

  defp legacy_username_alias_uri(_user, _legacy_base_url), do: nil

  @doc """
  Returns the outbox collection for a user.
  """
  def outbox(conn, %{"username" => identifier} = params) do
    requested_identifier = ActivityPub.actor_identifier(identifier)

    case Accounts.get_user_by_activitypub_identifier(requested_identifier) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        if user.activitypub_enabled do
          page = params["page"]
          render_outbox(conn, user, requested_identifier, page)
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "User not found"})
        end
    end
  end

  defp render_outbox(conn, user, requested_identifier, nil) do
    # Return the collection metadata
    base_url = activitypub_base_url_for_conn(conn)
    outbox_url = ActivityPub.user_collection_uri(requested_identifier, "outbox", base_url)
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

  defp render_outbox(conn, user, requested_identifier, page) do
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
    outbox_url = ActivityPub.user_collection_uri(requested_identifier, "outbox", base_url)

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
  def followers(conn, %{"username" => identifier}) do
    requested_identifier = ActivityPub.actor_identifier(identifier)

    case Accounts.get_user_by_activitypub_identifier(requested_identifier) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        if user.activitypub_enabled do
          base_url = activitypub_base_url_for_conn(conn)

          followers_url =
            ActivityPub.user_collection_uri(requested_identifier, "followers", base_url)

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
  def following(conn, %{"username" => identifier}) do
    requested_identifier = ActivityPub.actor_identifier(identifier)

    case Accounts.get_user_by_activitypub_identifier(requested_identifier) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        if user.activitypub_enabled do
          base_url = activitypub_base_url_for_conn(conn)

          following_url =
            ActivityPub.user_collection_uri(requested_identifier, "following", base_url)

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
  def object(conn, %{"username" => identifier, "id" => id}) do
    case Accounts.get_user_by_activitypub_identifier(identifier) do
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
            message = Elektrine.Repo.preload(message, :conversation)

            if user.activitypub_enabled and message.sender_id == user.id and
                 message.visibility == "public" and is_nil(message.deleted_at) and
                 message.is_draft != true and public_user_status_object?(message, user) do
              object_data = build_public_message_object(message, user)

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
    total_count =
      Elektrine.Social.count_hashtag_posts(hashtag.id,
        visibility: "public",
        exclude_drafts: true,
        activitypub_enabled_only: true
      )

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
    page_num = parse_page_number(page)
    limit = 20
    offset = (page_num - 1) * limit

    # Get public posts with this hashtag
    posts =
      Elektrine.Social.list_hashtag_posts(hashtag.id,
        visibility: "public",
        exclude_drafts: true,
        activitypub_enabled_only: true,
        limit: limit,
        offset: offset,
        preload: [:sender, :conversation]
      )

    # Build Note objects for each post
    items =
      Enum.map(posts, &build_hashtag_collection_item/1)
      |> Enum.reject(&is_nil/1)

    collection_page = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{collection_url}?page=#{page_num}",
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
  """
  def community_actor(conn, %{"name" => community_name}) do
    case fetch_public_community(community_name) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_resp_content_type("application/activity+json")
        |> json(%{error: "Community not found"})

      {:ok, community} ->
        actor_data = Builder.build_group(community)

        conn
        |> put_resp_content_type("application/activity+json")
        |> json(actor_data)
    end
  end

  @doc """
  Handles incoming activities to a community inbox.
  """
  def community_inbox(conn, %{"name" => community_name} = params) do
    case fetch_public_community(community_name) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Community not found"})

      {:ok, community} ->
        {:ok, _community_actor} = ActivityPub.get_or_create_community_actor(community.id)

        activity =
          params
          |> Map.drop(["name"])
          |> put_community_inbox_context(community)

        actor_uri = activity["actor"]

        if is_nil(actor_uri) do
          conn
          |> put_status(:bad_request)
          |> json(%{error: "Missing actor"})
        else
          case check_signature_validation(conn, activity, actor_uri) do
            :ok ->
              case validate_incoming_activity(activity, actor_uri) do
                {:ok, validated_activity} ->
                  case validate_inbound_delivery_policy(
                         validated_activity,
                         actor_uri,
                         nil,
                         community
                       ) do
                    :ok ->
                      log_inbound_group_activity(community, validated_activity, actor_uri)

                      _ = InboxQueue.enqueue(validated_activity, actor_uri, nil)

                      conn
                      |> put_status(:accepted)
                      |> json(%{})

                    {:error, reason} ->
                      Logger.info(
                        "Dropping community inbox activity #{inspect(validated_activity["id"])} for #{community.name} from #{format_actor_ref(actor_uri)}: #{inspect(reason)}"
                      )

                      conn
                      |> put_status(:accepted)
                      |> json(%{})
                  end

                {:error, :invalid_activity} ->
                  conn
                  |> put_status(:bad_request)
                  |> json(%{error: "Invalid activity"})
              end

            {:error, _reason} ->
              conn
              |> put_status(:unauthorized)
              |> json(%{error: "Invalid signature"})
          end
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
            post_count =
              Elektrine.Social.count_discussion_posts(community.id,
                visibility: "public",
                exclude_drafts: true,
                activitypub_enabled_only: true
              )

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
            page_num = parse_page_number(page)
            limit = 20
            offset = (page_num - 1) * limit

            posts =
              Elektrine.Social.get_discussion_posts(community.id,
                limit: limit,
                offset: offset,
                sort_by: "recent",
                visibility: "public",
                exclude_drafts: true,
                activitypub_enabled_only: true
              )

            items =
              Enum.map(posts, &build_public_community_create_activity(&1, community))

            collection_page = %{
              "@context" => "https://www.w3.org/ns/activitystreams",
              "id" => "#{outbox_url}?page=#{page_num}",
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

        total_count = follower_count

        collection =
          case conn.params["page"] do
            nil ->
              %{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => followers_url,
                "type" => "OrderedCollection",
                "totalItems" => total_count,
                "first" => "#{followers_url}?page=1"
              }

            page ->
              page_num = parse_page_number(page)

              %{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => "#{followers_url}?page=#{page_num}",
                "type" => "OrderedCollectionPage",
                "partOf" => followers_url,
                "orderedItems" => []
              }
          end

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
        moderator_uris = Builder.community_moderator_actor_uris(community, base_url)

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
      |> json(build_public_community_object(post, community))
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
      create_activity = build_public_community_create_activity(post, community)

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
      community
      when not is_nil(community) and community.is_public and
             community.is_federated_mirror != true ->
        {:ok, community}

      _ ->
        {:error, :not_found}
    end
  end

  defp fetch_public_community_post(community_id, message_id) do
    with {id, ""} <- Integer.parse(message_id),
         post when not is_nil(post) <- Elektrine.Messaging.get_message(id),
         post <- Elektrine.Repo.preload(post, :sender),
         true <- post.conversation_id == community_id and is_nil(post.deleted_at),
         true <- post.visibility == "public",
         true <- post.is_draft != true,
         true <- activitypub_visible_sender?(post.sender) do
      {:ok, post}
    else
      _ -> {:error, :not_found}
    end
  end

  defp activitypub_visible_sender?(%{activitypub_enabled: true}), do: true
  defp activitypub_visible_sender?(_), do: false

  defp fetch_community_by_identifier(identifier) do
    case ActivityPub.get_community_by_identifier(identifier) do
      %{type: "community"} = community -> community
      _ -> nil
    end
  end

  defp build_hashtag_collection_item(post) do
    cond do
      match?(%{conversation: %{type: "community", is_federated_mirror: true}}, post) and
          post.sender ->
        build_public_message_object(post, post.sender)

      match?(%{conversation: %{type: "community"}}, post) ->
        build_public_community_object(post, post.conversation)

      post.sender ->
        build_public_message_object(post, post.sender)

      true ->
        nil
    end
  end

  defp build_public_message_object(message, user) do
    base_object =
      case maybe_poll_for_message(message) do
        %{options: _} = poll -> Builder.build_question(message, user, poll)
        _ -> Builder.build_note(message, user)
      end

    preserve_original_object_routing(base_object, latest_local_create_activity(message, user))
  end

  defp build_public_community_object(post, community) do
    Builder.build_community_object(post, community, poll: maybe_poll_for_message(post))
  end

  defp build_public_community_create_activity(post, community) do
    post
    |> build_public_community_object(community)
    |> then(&Builder.build_community_create_activity(post, community, &1))
  end

  defp maybe_poll_for_message(%Message{post_type: "poll", id: message_id}) do
    case poll_schema() do
      nil ->
        nil

      poll_schema ->
        Elektrine.Repo.get_by(poll_schema, message_id: message_id)
        |> Elektrine.Repo.preload(:options)
    end
  end

  defp maybe_poll_for_message(_), do: nil

  defp poll_schema do
    if Code.ensure_loaded?(Elektrine.Social.Poll), do: Elektrine.Social.Poll, else: nil
  end

  defp community_message?(%{conversation: %{type: "community"}}), do: true
  defp community_message?(_), do: false

  defp public_user_status_object?(message, user) do
    case message.activitypub_id do
      value when is_binary(value) and value != "" ->
        comparable_uri(value) in Enum.map(
          user_status_uri_candidates(user, message),
          &comparable_uri/1
        )

      _ ->
        not community_message?(message)
    end
  end

  defp user_status_uri_candidates(user, message) do
    base_urls =
      [ActivityPub.instance_url()] ++
        case Domains.activitypub_move_from_domain() do
          legacy_domain when is_binary(legacy_domain) ->
            [ActivityPub.instance_url_for_domain(legacy_domain)]

          _ ->
            []
        end

    for base_url <- base_urls,
        identifier <- ActivityPub.actor_identifiers(user),
        uri = ActivityPub.user_status_uri(identifier, message.id, base_url),
        uniq: true,
        do: uri
  end

  defp latest_local_create_activity(message, user) do
    user
    |> user_status_uri_candidates(message)
    |> Enum.find_value(fn object_id ->
      ActivityPub.get_latest_local_activity(user.id, "Create", object_id)
    end)
  end

  defp preserve_original_object_routing(object, nil), do: object

  defp preserve_original_object_routing(object, %{data: data})
       when is_map(object) and is_map(data) do
    case Map.get(data, "object") do
      original_object when is_map(original_object) ->
        Enum.reduce(["to", "cc", "audience", "context"], object, fn field, acc ->
          case Map.get(original_object, field) do
            nil -> acc
            value -> Map.put(acc, field, value)
          end
        end)

      _ ->
        object
    end
  end

  defp preserve_original_object_routing(object, _), do: object

  defp log_inbound_group_activity(community, activity, actor_uri) do
    activity_type = Map.get(activity, "type", "unknown")
    object = Map.get(activity, "object")

    if activity_type in ["Follow", "Accept", "Create", "Announce"] do
      Logger.info(
        "Community inbox accepted #{activity_type} for #{community.name} from #{format_actor_ref(actor_uri)} object=#{inspect(object)}"
      )
    end
  end

  defp put_community_inbox_context(activity, community) do
    activity
    |> Map.put("_elektrine_target_community_id", community.id)
    |> Map.put("_elektrine_target_community_uri", ActivityPub.community_actor_uri(community.name))
  end

  defp validate_inbound_delivery_policy(activity, actor_uri, target_user, target_community) do
    if content_distribution_activity?(activity) do
      cond do
        local_user_targeted?(activity, target_user) ->
          :ok

        local_community_targeted?(activity, target_community) ->
          :ok

        references_known_message?(activity) ->
          :ok

        locally_followed_actor?(actor_uri) ->
          :ok

        ActivityPub.active_relay_actor_uri?(actor_uri) ->
          :ok

        true ->
          {:error, :not_addressed_to_local_audience}
      end
    else
      :ok
    end
  end

  defp content_distribution_activity?(%{"type" => type}) when type in ["Create", "Announce"],
    do: true

  defp content_distribution_activity?(_), do: false

  defp local_user_targeted?(activity, nil) do
    activity
    |> activity_recipient_refs()
    |> Enum.any?(&local_user_ref?/1)
  end

  defp local_user_targeted?(activity, user) do
    target_uris = user_delivery_uris(user) |> Enum.map(&comparable_uri/1)

    activity
    |> activity_recipient_refs()
    |> Enum.map(&comparable_uri/1)
    |> Enum.any?(&(&1 in target_uris))
  end

  defp local_community_targeted?(_activity, nil), do: false

  defp local_community_targeted?(activity, community) do
    target_uris = community_delivery_uris(community) |> Enum.map(&comparable_uri/1)

    activity
    |> activity_recipient_refs()
    |> Enum.map(&comparable_uri/1)
    |> Enum.any?(&(&1 in target_uris))
  end

  defp references_known_message?(activity) do
    activity
    |> activity_object_refs()
    |> Enum.any?(&known_message_ref?/1)
  end

  defp locally_followed_actor?(actor_uri) when is_binary(actor_uri) do
    case ActivityPub.get_actor_by_uri(actor_uri) do
      %Elektrine.ActivityPub.Actor{id: actor_id} ->
        Profiles.any_local_following_remote_actor?(actor_id)

      _ ->
        false
    end
  end

  defp locally_followed_actor?(_), do: false

  defp activity_recipient_refs(activity) when is_map(activity) do
    object = if is_map(activity["object"]), do: activity["object"], else: %{}

    [
      activity["to"],
      activity["cc"],
      activity["bto"],
      activity["bcc"],
      activity["audience"],
      activity["target"],
      object["to"],
      object["cc"],
      object["bto"],
      object["bcc"],
      object["audience"],
      object["target"],
      object["context"],
      mention_hrefs(object)
    ]
    |> Enum.flat_map(&expand_uri_candidates/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp activity_recipient_refs(_), do: []

  defp activity_object_refs(activity) when is_map(activity) do
    object = Map.get(activity, "object")

    [
      object,
      object_ref_field(object, "id"),
      object_ref_field(object, "url"),
      object_ref_field(object, "href"),
      object_ref_field(object, "inReplyTo")
    ]
    |> Enum.flat_map(&expand_uri_candidates/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp activity_object_refs(_), do: []

  defp object_ref_field(object, field) when is_map(object), do: Map.get(object, field)
  defp object_ref_field(_, _), do: nil

  defp mention_hrefs(%{"tag" => tags}) when is_list(tags) do
    tags
    |> Enum.filter(&(Map.get(&1, "type") == "Mention"))
    |> Enum.map(&Map.get(&1, "href"))
  end

  defp mention_hrefs(_), do: []

  defp local_user_ref?(ref) when is_binary(ref) do
    case ActivityPub.local_username_from_uri(ref) do
      {:ok, _username} -> true
      _ -> false
    end
  end

  defp local_user_ref?(_), do: false

  defp known_message_ref?(ref) when is_binary(ref) do
    match?(%{}, Messaging.get_message_by_activitypub_ref(ref))
  end

  defp known_message_ref?(_), do: false

  defp user_delivery_uris(user) do
    for identifier <- ActivityPub.actor_identifiers(user),
        uri <- [
          ActivityPub.actor_uri(identifier),
          ActivityPub.user_collection_uri(identifier, "followers")
        ],
        is_binary(uri),
        do: uri
  end

  defp community_delivery_uris(community) do
    [
      ActivityPub.community_actor_uri(community.name),
      ActivityPub.community_followers_uri(community.name),
      Map.get(community, :activitypub_id)
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp validate_incoming_activity(activity, actor_uri) do
    case ObjectValidator.validate(activity) do
      {:ok, validated_activity} ->
        {:ok, validated_activity}

      {:error, reason} ->
        Logger.warning("Invalid activity from #{format_actor_ref(actor_uri)}: #{reason}")
        {:error, :invalid_activity}
    end
  end
end
