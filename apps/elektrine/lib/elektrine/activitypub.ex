defmodule Elektrine.ActivityPub do
  @moduledoc """
  The ActivityPub context for federation.
  Handles actors, activities, and federation with other instances.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo

  alias Elektrine.ActivityPub.{
    Activity,
    ActivityDeliveryWorker,
    Actor,
    Delivery,
    Fetcher,
    Instance,
    KeyManager,
    MastodonApi,
    RelaySubscription,
    UserBlock
  }

  alias Elektrine.Messaging.Conversations

  @doc """
  Gets the instance domain for this server.
  """
  def instance_domain do
    System.get_env("INSTANCE_DOMAIN") || "z.org"
  end

  @doc """
  Gets the instance base URL.
  """
  def instance_url do
    domain = instance_domain()

    # Check if using ngrok or other external tunnel (contains a dot and not localhost)
    is_tunnel = String.contains?(domain, ".") and not String.starts_with?(domain, "localhost")

    # Use HTTPS for production or tunnels (ngrok, etc.)
    scheme = if System.get_env("MIX_ENV") == "prod" or is_tunnel, do: "https", else: "http"
    port = System.get_env("PORT") || "4000"

    # Don't include port for HTTPS, standard ports, or tunnels
    if scheme == "https" or port == "80" or port == "443" or is_tunnel do
      "#{scheme}://#{domain}"
    else
      "#{scheme}://#{domain}:#{port}"
    end
  end

  @doc """
  Returns local actor URI prefixes used to detect local `/users/:username` actor URLs.
  """
  def local_actor_prefixes do
    configured_domains =
      Application.get_env(:elektrine, :email, [])
      |> Keyword.get(:supported_domains, [])

    domains =
      ([instance_domain()] ++ configured_domains)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    urls =
      [instance_url()] ++
        Enum.flat_map(domains, fn domain -> ["https://#{domain}", "http://#{domain}"] end)

    urls
    |> Enum.uniq()
    |> Enum.map(&(String.trim_trailing(&1, "/") <> "/users/"))
  end

  ## Actors

  @doc """
  Gets or creates a remote actor by their URI.
  Fetches the actor document if not cached or stale.
  Uses in-memory caching to reduce database load during high traffic.
  """
  def get_or_fetch_actor(uri) when is_binary(uri) do
    Elektrine.AppCache.get_actor(uri, fn ->
      do_get_or_fetch_actor(uri)
    end)
  end

  defp do_get_or_fetch_actor(uri) do
    case get_actor_by_uri(uri) do
      nil ->
        fetch_and_cache_actor(uri)

      %Actor{last_fetched_at: nil} = actor ->
        # Never fetched, refresh
        fetch_and_cache_actor(uri, actor)

      %Actor{last_fetched_at: last_fetched} = actor ->
        # Refresh if older than 24 hours
        if DateTime.diff(DateTime.utc_now(), last_fetched, :hour) > 24 do
          fetch_and_cache_actor(uri, actor)
        else
          {:ok, actor}
        end
    end
  end

  @doc """
  Gets an actor by their ActivityPub URI.
  """
  def get_actor_by_uri(uri) do
    Repo.get_by(Actor, uri: uri)
  end

  @doc """
  Gets a remote actor by their database ID.
  """
  def get_remote_actor(id) do
    Repo.get(Actor, id)
  end

  @doc """
  Gets an actor by username and domain.
  Returns the oldest actor if duplicates exist (to be cleaned up by migration).
  """
  def get_actor_by_username_and_domain(username, domain) do
    import Ecto.Query

    from(a in Actor,
      where: a.username == ^username and a.domain == ^domain,
      order_by: [asc: a.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Fetches an actor document from a remote instance and caches it.
  """
  def fetch_and_cache_actor(uri, existing_actor \\ nil) do
    with {:ok, actor_data} <- Fetcher.fetch_actor(uri),
         {:ok, actor} <- cache_actor(actor_data, existing_actor) do
      {:ok, actor}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp cache_actor(actor_data, existing_actor) do
    uri = URI.parse(actor_data["id"])
    domain = uri.host

    # Ensure instance record exists
    get_or_create_instance(domain)

    # Extract and cache custom emojis from actor profile
    Task.start(fn ->
      Elektrine.Emojis.process_activitypub_tags(actor_data["tag"], domain)
    end)

    # Extract username from preferredUsername or id
    username =
      actor_data["preferredUsername"] ||
        extract_username_from_uri(actor_data["id"])

    # Parse the published date from the actor data
    published_at =
      case actor_data["published"] do
        nil ->
          nil

        date_string ->
          case DateTime.from_iso8601(date_string) do
            {:ok, datetime, _} -> DateTime.truncate(datetime, :second)
            _ -> nil
          end
      end

    attrs = %{
      uri: actor_data["id"],
      username: username,
      domain: domain,
      display_name: actor_data["name"],
      summary: actor_data["summary"],
      avatar_url: get_icon_url(actor_data),
      header_url: get_image_url(actor_data),
      inbox_url: actor_data["inbox"],
      outbox_url: actor_data["outbox"],
      followers_url: actor_data["followers"],
      following_url: actor_data["following"],
      public_key: extract_public_key(actor_data),
      manually_approves_followers: actor_data["manuallyApprovesFollowers"] || false,
      actor_type: actor_data["type"] || "Person",
      last_fetched_at: DateTime.utc_now(),
      published_at: published_at,
      moderators_url: actor_data["moderators"],
      metadata: actor_data
    }

    upsert_cached_actor(existing_actor, attrs)
  end

  defp upsert_cached_actor(%Actor{} = existing_actor, attrs) do
    existing_actor
    |> Actor.changeset(attrs)
    |> Repo.update()
  end

  defp upsert_cached_actor(nil, attrs) do
    case %Actor{} |> Actor.changeset(attrs) |> Repo.insert() do
      {:ok, actor} ->
        {:ok, actor}

      {:error, %Ecto.Changeset{} = changeset} ->
        recover_actor_conflict(attrs, changeset)
    end
  end

  # During federation bursts, multiple requests can race to create the same actor
  # (or a canonicalized variant such as trailing-slash URI differences).
  # Recover by reloading and refreshing the existing row instead of failing.
  defp recover_actor_conflict(attrs, original_changeset) do
    actor =
      get_actor_by_uri(attrs.uri) ||
        get_actor_by_username_and_domain(attrs.username, attrs.domain)

    case actor do
      nil ->
        {:error, original_changeset}

      %Actor{} = existing_actor ->
        case existing_actor |> Actor.changeset(attrs) |> Repo.update() do
          {:ok, updated_actor} ->
            {:ok, updated_actor}

          {:error, _changeset} ->
            attrs_without_identity = Map.drop(attrs, [:uri, :username, :domain])

            case existing_actor
                 |> Actor.changeset(attrs_without_identity)
                 |> Repo.update() do
              {:ok, updated_actor} -> {:ok, updated_actor}
              {:error, _} -> {:ok, existing_actor}
            end
        end
    end
  end

  defp extract_username_from_uri(uri) do
    # Extract username from URIs like https://mastodon.social/users/alice
    uri
    |> String.split("/")
    |> List.last()
  end

  defp get_icon_url(%{"icon" => %{"url" => url}}), do: url
  defp get_icon_url(%{"icon" => url}) when is_binary(url), do: url
  defp get_icon_url(_), do: nil

  defp get_image_url(%{"image" => %{"url" => url}}), do: url
  defp get_image_url(%{"image" => url}) when is_binary(url), do: url
  defp get_image_url(_), do: nil

  defp extract_public_key(%{"publicKey" => %{"publicKeyPem" => pem}}), do: pem
  defp extract_public_key(_), do: nil

  ## Activities

  @doc """
  Creates an activity.
  """
  def create_activity(attrs) do
    %Activity{}
    |> Activity.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets an activity by its ActivityPub ID.
  """
  def get_activity_by_id(activity_id) do
    Repo.get_by(Activity, activity_id: activity_id)
  end

  @doc """
  Lists activities for a user's outbox.
  """
  def list_outbox_activities(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    Activity
    |> where([a], a.internal_user_id == ^user_id and a.local == true)
    |> where([a], a.activity_type in ["Create", "Announce"])
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Counts local outbox activities for a user.
  """
  def count_outbox_activities(user_id) do
    Activity
    |> where([a], a.internal_user_id == ^user_id and a.local == true)
    |> where([a], a.activity_type in ["Create", "Announce"])
    |> Repo.aggregate(:count, :id)
  end

  ## Deliveries

  @doc """
  Creates delivery records for an activity to be sent to remote inboxes.
  Also enqueues Oban jobs for processing.
  """
  def create_deliveries(activity_id, inbox_urls) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    deliveries =
      Enum.map(inbox_urls, fn inbox_url ->
        %{
          activity_id: activity_id,
          inbox_url: inbox_url,
          status: "pending",
          attempts: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, inserted} = Repo.insert_all(Delivery, deliveries, returning: [:id])

    # Enqueue Oban jobs for the inserted deliveries
    if count > 0 do
      delivery_ids = Enum.map(inserted, & &1.id)
      ActivityDeliveryWorker.enqueue_many(delivery_ids)
    end

    {count, inserted}
  end

  @doc """
  Gets a delivery by ID with its associated activity.
  """
  def get_delivery(delivery_id) do
    Delivery
    |> where([d], d.id == ^delivery_id)
    |> preload(:activity)
    |> Repo.one()
  end

  @doc """
  Gets pending deliveries that are ready to be attempted.
  """
  def get_pending_deliveries(limit \\ 100) do
    now = DateTime.utc_now()

    Delivery
    |> where([d], d.status == "pending")
    |> where([d], is_nil(d.next_retry_at) or d.next_retry_at <= ^now)
    |> where([d], d.attempts < 10)
    |> limit(^limit)
    |> preload(:activity)
    |> Repo.all()
  end

  @doc """
  Gets delivery IDs that are pending and ready to be retried.
  """
  def get_retryable_delivery_ids(limit \\ 500) do
    now = DateTime.utc_now()

    Delivery
    |> where([d], d.status == "pending")
    |> where([d], is_nil(d.next_retry_at) or d.next_retry_at <= ^now)
    |> where([d], d.attempts < 10)
    |> order_by([d], asc: d.updated_at)
    |> limit(^limit)
    |> select([d], d.id)
    |> Repo.all()
  end

  @doc """
  Marks a delivery as delivered.
  """
  def mark_delivery_delivered(delivery_id) do
    Delivery
    |> Repo.get(delivery_id)
    |> Delivery.changeset(%{
      status: "delivered",
      last_attempt_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc """
  Cleans up old failed deliveries (older than 7 days).
  Returns count of deleted deliveries.
  """
  def cleanup_old_deliveries do
    seven_days_ago = DateTime.utc_now() |> DateTime.add(-7, :day)

    {count, _} =
      from(d in Delivery,
        where: d.status == "failed" and d.inserted_at < ^seven_days_ago
      )
      |> Repo.delete_all()

    count
  end

  @doc """
  Marks a delivery as failed and schedules retry.
  """
  def mark_delivery_failed(delivery_id, error_message) do
    delivery = Repo.get(Delivery, delivery_id)
    attempts = delivery.attempts + 1

    # Exponential backoff: 5min, 15min, 1hr, 3hr, 12hr, 24hr, then give up
    next_retry_minutes =
      case attempts do
        1 -> 5
        2 -> 15
        3 -> 60
        4 -> 180
        5 -> 720
        6 -> 1440
        _ -> nil
      end

    next_retry_at =
      if next_retry_minutes do
        DateTime.add(DateTime.utc_now(), next_retry_minutes * 60, :second)
      else
        nil
      end

    status = if attempts >= 10, do: "failed", else: "pending"

    delivery
    |> Delivery.changeset(%{
      status: status,
      attempts: attempts,
      last_attempt_at: DateTime.utc_now(),
      next_retry_at: next_retry_at,
      error_message: error_message
    })
    |> Repo.update()
  end

  ## Instances

  @doc """
  Gets or creates an instance record.
  """
  def get_or_create_instance(domain) do
    case Repo.get_by(Instance, domain: domain) do
      nil ->
        %Instance{}
        |> Instance.changeset(%{domain: domain})
        |> Repo.insert()

      instance ->
        {:ok, instance}
    end
  end

  @doc """
  Checks if an instance is blocked.
  """
  def instance_blocked?(domain) do
    case Repo.get_by(Instance, domain: domain) do
      %Instance{blocked: true} -> true
      _ -> false
    end
  end

  @doc """
  Blocks an instance.
  """
  def block_instance(domain, reason, admin_user_id) do
    case get_or_create_instance(domain) do
      {:ok, instance} ->
        instance
        |> Instance.changeset(%{
          blocked: true,
          reason: reason,
          blocked_by_id: admin_user_id,
          blocked_at: DateTime.utc_now()
        })
        |> Repo.update()

      error ->
        error
    end
  end

  ## User blocks

  @doc """
  Blocks a remote actor or domain for a specific user.
  """
  def block_for_user(user_id, blocked_uri, type \\ "user") do
    %UserBlock{}
    |> UserBlock.changeset(%{
      user_id: user_id,
      blocked_uri: blocked_uri,
      block_type: type
    })
    |> Repo.insert()
  end

  @doc """
  Checks if a user has blocked an actor or domain.
  """
  def user_blocked?(user_id, uri) do
    # Check both direct URI block and domain block
    %URI{host: domain} = URI.parse(uri)

    UserBlock
    |> where([b], b.user_id == ^user_id)
    |> where(
      [b],
      b.blocked_uri == ^uri or (b.block_type == "domain" and b.blocked_uri == ^domain)
    )
    |> Repo.exists?()
  end

  ## Relays (stub functions for now - full relay implementation exists in relay_manager.ex)

  @doc """
  Gets all relay inbox URLs for sending activities.
  """
  def get_relay_inboxes do
    from(s in RelaySubscription,
      where: s.status == "active" and s.accepted == true and not is_nil(s.relay_inbox),
      select: s.relay_inbox
    )
    |> Repo.all()
    |> Enum.uniq()
  end

  ## Community/Group Actors

  @doc """
  Gets or creates an ActivityPub Group actor for a local community.
  """
  def get_or_create_community_actor(community_id) when is_integer(community_id) do
    case Repo.get_by(Actor, community_id: community_id) do
      nil ->
        # Fetch the community
        case Conversations.get_conversation_basic(community_id) do
          {:ok, community} ->
            create_community_actor(community)

          {:error, _} ->
            {:error, :community_not_found}
        end

      actor ->
        ensure_community_actor_keys(actor)
    end
  end

  defp create_community_actor(community) do
    base_url = instance_url()
    community_slug = String.downcase(community.name) |> String.replace(~r/[^a-z0-9]+/, "-")
    actor_url = "#{base_url}/c/#{community_slug}"

    attrs = %{
      uri: actor_url,
      username: community_slug,
      domain: instance_domain(),
      display_name: community.name,
      summary: community.description,
      avatar_url: community.avatar_url,
      inbox_url: "#{actor_url}/inbox",
      outbox_url: "#{actor_url}/outbox",
      followers_url: "#{actor_url}/followers",
      public_key: nil,
      manually_approves_followers: !community.is_public,
      actor_type: "Group",
      community_id: community.id,
      published_at: community.inserted_at,
      last_fetched_at: DateTime.utc_now(),
      metadata: %{}
    }

    case %Actor{}
         |> Actor.changeset(attrs)
         |> Repo.insert() do
      {:ok, actor} -> ensure_community_actor_keys(actor)
      error -> error
    end
  end

  defp ensure_community_actor_keys(%Actor{} = actor) do
    case KeyManager.ensure_user_has_keys(actor) do
      {:ok, actor_with_keys} -> {:ok, actor_with_keys}
      {:error, _reason} -> {:ok, actor}
    end
  end

  @doc """
  Gets a community actor by community name.
  """
  def get_community_actor_by_name(name) do
    community_slug = String.downcase(name) |> String.replace(~r/[^a-z0-9]+/, "-")

    Repo.get_by(Actor,
      username: community_slug,
      domain: instance_domain(),
      actor_type: "Group"
    )
  end

  @doc """
  Fetches a remote user's timeline from their outbox.
  Returns a list of post objects from their public timeline.
  """
  def fetch_remote_user_timeline(remote_actor_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    case Repo.get(Actor, remote_actor_id) do
      nil ->
        {:error, :actor_not_found}

      %Actor{outbox_url: nil} ->
        {:error, :no_outbox_url}

      %Actor{outbox_url: outbox_url} ->
        case Fetcher.fetch_object(outbox_url) do
          {:ok, outbox_data} ->
            posts = extract_posts_from_outbox(outbox_data, limit)
            {:ok, posts}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp extract_posts_from_outbox(outbox_data, limit) do
    # Handle both OrderedCollection and Collection
    items =
      case outbox_data do
        %{"orderedItems" => items} when is_list(items) ->
          items

        %{"items" => items} when is_list(items) ->
          items

        # Handle first as a URL string
        %{"first" => first_page_url} when is_binary(first_page_url) ->
          fetch_collection_page_items(first_page_url)

        # Handle first as an object with id
        %{"first" => %{"id" => first_page_url}} when is_binary(first_page_url) ->
          fetch_collection_page_items(first_page_url)

        # Handle first as an object with items directly
        %{"first" => %{"orderedItems" => items}} when is_list(items) ->
          items

        %{"first" => %{"items" => items}} when is_list(items) ->
          items

        _ ->
          []
      end

    # Filter and extract posts
    # Handle Create, Announce activities and unwrapped objects
    items
    |> Enum.map(fn item ->
      case item do
        # Create activity wrapping an object
        %{"type" => "Create", "object" => %{"type" => type} = object}
        when type in ["Note", "Article", "Question", "Page"] ->
          object

        # Announce activity wrapping a Create activity
        %{
          "type" => "Announce",
          "object" => %{"type" => "Create", "object" => %{"type" => type} = inner_object}
        }
        when type in ["Note", "Article", "Question", "Page"] ->
          inner_object

        # Announce activity with direct embedded object (some instances)
        %{"type" => "Announce", "object" => %{"type" => type} = object}
        when type in ["Note", "Article", "Question", "Page"] ->
          object

        # Announce activity where object is a URL
        %{"type" => "Announce", "object" => object_url} when is_binary(object_url) ->
          case Fetcher.fetch_object(object_url) do
            {:ok, %{"type" => type} = object}
            when type in ["Note", "Article", "Question", "Page"] ->
              object

            {:ok, %{"type" => "Create", "object" => %{"type" => type} = inner_object}}
            when type in ["Note", "Article", "Question", "Page"] ->
              inner_object

            _ ->
              nil
          end

        # Direct Note/Page object (some instances send these directly)
        %{"type" => type} = object when type in ["Note", "Article", "Question", "Page"] ->
          object

        # URL string - need to fetch the object
        url when is_binary(url) ->
          case Fetcher.fetch_object(url) do
            {:ok, %{"type" => type} = object}
            when type in ["Note", "Article", "Question", "Page"] ->
              object

            {:ok, %{"type" => "Create", "object" => %{"type" => type} = inner_object}}
            when type in ["Note", "Article", "Question", "Page"] ->
              inner_object

            _ ->
              nil
          end

        _ ->
          nil
      end
    end)
    |> Enum.filter(fn post ->
      post &&
        post["inReplyTo"] in [nil, ""] &&
        post["type"] in [
          "Page",
          "Article",
          "Question",
          # Mastodon/Pleroma top-level statuses are usually Note.
          # Comments are filtered by inReplyTo above.
          "Note"
        ]
    end)
    |> Enum.take(limit)
  end

  defp fetch_collection_page_items(url) do
    case Fetcher.fetch_object(url) do
      {:ok, page} ->
        case page do
          %{"orderedItems" => items} when is_list(items) -> items
          %{"items" => items} when is_list(items) -> items
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc """
  Fetches replies for a remote post.
  Returns a list of reply objects.
  """
  def fetch_remote_post_replies(post_object, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    post_url = post_object["url"] || post_object["id"]

    # Prefer standard replies collection, but accept comments collections used by
    # some platforms.
    replies_url =
      extract_collection_url(post_object["replies"]) ||
        extract_collection_url(post_object["comments"])

    expected_replies =
      [
        normalize_reply_count(post_object["repliesCount"]),
        normalize_reply_count(collection_total_items(post_object["replies"])),
        normalize_reply_count(collection_total_items(post_object["comments"]))
      ]
      |> Enum.max(fn -> 0 end)

    has_replies_count = expected_replies > 0
    post_id = post_object["id"] || post_url

    cond do
      # Standard ActivityPub replies collection
      replies_url != nil ->
        case fetch_replies_from_collection(replies_url, limit) do
          {:ok, replies} when replies != [] ->
            {:ok, replies}

          other ->
            cond do
              # Lemmy-style posts may expose empty AP collections but still have API comments.
              (expected_replies > 0 and post_object["type"] == "Page") &&
                  lemmy_post_url?(post_url) ->
                fetch_lemmy_comments(post_url, limit)

              # ActivityPub collection returned empty but we expect replies - try Mastodon API
              expected_replies > 0 and is_binary(post_url) ->
                fetch_mastodon_context_replies(post_url, limit)

              true ->
                other
            end
        end

      # Page type post - try instance-specific API
      post_object["type"] == "Page" && lemmy_post_url?(post_url) ->
        fetch_lemmy_comments(post_url, limit)

      # Has replies count but no replies field - try Mastodon API first, then Pleroma
      has_replies_count && is_binary(post_url) ->
        case fetch_mastodon_context_replies(post_url, limit) do
          {:ok, replies} when replies != [] -> {:ok, replies}
          _ -> fetch_pleroma_replies(post_id, limit)
        end

      true ->
        {:ok, []}
    end
  end

  defp extract_collection_url(%{"first" => %{"id" => id}}) when is_binary(id), do: id
  defp extract_collection_url(%{"first" => first_url}) when is_binary(first_url), do: first_url
  defp extract_collection_url(%{"id" => id}) when is_binary(id), do: id
  defp extract_collection_url(url) when is_binary(url), do: url
  defp extract_collection_url(_), do: nil

  defp collection_total_items(collection) when is_map(collection) do
    Map.get(collection, "totalItems") || Map.get(collection, :totalItems)
  end

  defp collection_total_items(_), do: nil

  defp normalize_reply_count(value) when is_integer(value), do: max(value, 0)

  defp normalize_reply_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp normalize_reply_count(_), do: 0

  # Fetch replies using Mastodon's /api/v1/statuses/:id/context endpoint
  defp fetch_mastodon_context_replies(post_url, limit) do
    case MastodonApi.fetch_status_context(post_url) do
      {:ok, descendants} ->
        # Convert Mastodon API format to ActivityPub-like objects
        replies =
          descendants
          |> Enum.take(limit)
          |> Enum.map(fn status ->
            in_reply_to =
              cond do
                is_binary(status.in_reply_to_uri) ->
                  status.in_reply_to_uri

                status.in_reply_to_id ->
                  post_url

                true ->
                  nil
              end

            %{
              "id" => status.uri || status.url || "#{post_url}#status-#{status.id}",
              "url" => status.url || status.uri,
              "type" => "Note",
              "content" => status.content,
              "attributedTo" => status.account[:url] || status.account[:uri],
              "published" => status.created_at,
              "inReplyTo" => in_reply_to,
              "likes" => %{"totalItems" => status.favourites_count},
              "shares" => %{"totalItems" => status.reblogs_count},
              "replies" => %{"totalItems" => status.replies_count},
              "_mastodon_account" => status.account
            }
          end)

        {:ok, replies}

      {:error, _} ->
        {:ok, []}
    end
  end

  # Check if URL is a community-post format across Lemmy/PieFed/Mbin.
  defp lemmy_post_url?(url) when is_binary(url) do
    String.contains?(url, "/post/") ||
      Regex.match?(~r{/c/[^/]+/p/\d+}, url) ||
      Regex.match?(~r{/m/[^/]+/[pt]/\d+}, url)
  end

  defp lemmy_post_url?(_), do: false

  # Fetch comments from instance API
  defp fetch_lemmy_comments(post_url, limit) do
    case resolve_lemmy_post_reference(post_url) do
      {:ok, domain, post_id} ->
        # First try the origin domain
        case fetch_lemmy_comments_from_instance(domain, post_id, post_url, limit) do
          {:ok, comments} when comments != [] ->
            {:ok, comments}

          _ ->
            # If empty, try to find the community's home instance
            # The post might be federated from another instance
            try_fetch_from_community_instance(post_url, limit)
        end

      :error ->
        {:ok, []}
    end
  end

  defp resolve_lemmy_post_reference(post_url) do
    case Regex.run(~r{https?://([^/]+)/post/(\d+)}, post_url) do
      [_, domain, post_id] ->
        {:ok, domain, post_id}

      _ ->
        case Regex.run(~r{https?://([^/]+)/c/[^/]+/p/(\d+)}, post_url) do
          [_, domain, post_id] ->
            {:ok, domain, post_id}

          _ ->
            case Regex.run(~r{https?://([^/]+)/m/[^/]+/[pt]/(\d+)}, post_url) do
              [_, domain, post_id] ->
                {:ok, domain, post_id}

              _ ->
                resolve_lemmy_post_reference_via_api(post_url)
            end
        end
    end
  end

  defp resolve_lemmy_post_reference_via_api(post_url) do
    case URI.parse(post_url) do
      %URI{host: domain} when is_binary(domain) ->
        resolve_url = "https://#{domain}/api/v3/resolve_object?q=#{URI.encode_www_form(post_url)}"

        case Finch.build(:get, resolve_url, [{"Accept", "application/json"}])
             |> Finch.request(Elektrine.Finch, receive_timeout: 10_000) do
          {:ok, %Finch.Response{status: 200, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"post" => %{"post" => %{"id" => post_id}}}} when is_integer(post_id) ->
                {:ok, domain, Integer.to_string(post_id)}

              {:ok, %{"post" => %{"post" => %{"id" => post_id}}}} when is_binary(post_id) ->
                {:ok, domain, post_id}

              _ ->
                :error
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  # Try to fetch comments from the community's home instance
  defp try_fetch_from_community_instance(post_url, limit) do
    # Fetch the post object to get the audience (community)
    case Fetcher.fetch_object(post_url) do
      {:ok, post_object} ->
        # Get the community URL from audience field
        community_url = post_object["audience"]

        if is_binary(community_url) do
          # Extract community's home domain
          case URI.parse(community_url) do
            %URI{host: community_domain} when is_binary(community_domain) ->
              # Resolve the post on the community's home instance
              resolve_url =
                "https://#{community_domain}/api/v3/resolve_object?q=#{URI.encode_www_form(post_url)}"

              case Finch.build(:get, resolve_url, [{"Accept", "application/json"}])
                   |> Finch.request(Elektrine.Finch, receive_timeout: 10_000) do
                {:ok, %Finch.Response{status: 200, body: body}} ->
                  case Jason.decode(body) do
                    {:ok, %{"post" => %{"post" => %{"id" => local_post_id}}}} ->
                      # Now fetch comments using the local post ID
                      fetch_lemmy_comments_from_instance(
                        community_domain,
                        to_string(local_post_id),
                        post_url,
                        limit
                      )

                    _ ->
                      {:ok, []}
                  end

                _ ->
                  {:ok, []}
              end

            _ ->
              {:ok, []}
          end
        else
          {:ok, []}
        end

      _ ->
        {:ok, []}
    end
  end

  # Fetch comments from a specific instance
  defp fetch_lemmy_comments_from_instance(domain, post_id, post_url, limit) do
    api_url = "https://#{domain}/api/v3/comment/list?post_id=#{post_id}&limit=#{limit}&sort=Top"

    case Finch.build(:get, api_url, [{"Accept", "application/json"}])
         |> Finch.request(Elektrine.Finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"comments" => comments}} when is_list(comments) ->
            # Convert Lemmy comments to ActivityPub-like format
            replies =
              Enum.map(comments, fn comment_data ->
                comment = comment_data["comment"]
                creator = comment_data["creator"]
                counts = comment_data["counts"] || %{}

                %{
                  "id" => comment["ap_id"],
                  "type" => "Note",
                  "content" => comment["content"],
                  "attributedTo" => creator["actor_id"],
                  "published" => comment["published"],
                  "inReplyTo" => parse_lemmy_reply_path(comment["path"], post_url),
                  # Store extra Lemmy-specific data including counts
                  "_lemmy" => %{
                    "creator_name" => creator["name"],
                    "creator_avatar" => creator["avatar"],
                    "path" => comment["path"],
                    "score" => counts["score"] || 0,
                    "upvotes" => counts["upvotes"] || 0,
                    "downvotes" => counts["downvotes"] || 0,
                    "child_count" => counts["child_count"] || 0
                  }
                }
              end)

            {:ok, replies}

          _ ->
            {:ok, []}
        end

      _ ->
        {:ok, []}
    end
  end

  # Parse comment path to determine inReplyTo
  defp parse_lemmy_reply_path(path, post_url) when is_binary(path) do
    parts = String.split(path, ".")

    case parts do
      # Top-level comment: "0.commentId" - replies to post
      ["0", _comment_id] ->
        post_url

      # Nested comment: "0.parentId.commentId..." - replies to parent
      ["0" | rest] when length(rest) >= 2 ->
        # The second-to-last element is the parent comment ID
        # But we need the AP ID, which we don't have here
        # Fall back to the post URL until comment-thread mapping is available.
        post_url

      _ ->
        post_url
    end
  end

  defp parse_lemmy_reply_path(_, post_url), do: post_url

  # Fetch replies using context API (Mastodon/Pleroma/Akkoma)
  defp fetch_pleroma_replies(post_ap_id, limit) do
    require Logger

    # Extract domain from the ActivityPub ID
    case URI.parse(post_ap_id) do
      %URI{host: domain} when is_binary(domain) ->
        # Step 1: Search for the post to get its internal ID
        search_url =
          "https://#{domain}/api/v2/search?q=#{URI.encode_www_form(post_ap_id)}&type=statuses&resolve=true&limit=1"

        case Finch.build(:get, search_url, [{"Accept", "application/json"}])
             |> Finch.request(Elektrine.Finch, receive_timeout: 15_000) do
          {:ok, %Finch.Response{status: 200, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"statuses" => [%{"id" => status_id, "uri" => root_uri} = root_status | _]}} ->
                # Step 2: Fetch context (ancestors + descendants)
                context_url = "https://#{domain}/api/v1/statuses/#{status_id}/context"

                case Finch.build(:get, context_url, [{"Accept", "application/json"}])
                     |> Finch.request(Elektrine.Finch, receive_timeout: 15_000) do
                  {:ok, %Finch.Response{status: 200, body: context_body}} ->
                    case Jason.decode(context_body) do
                      {:ok, %{"ancestors" => ancestors, "descendants" => descendants}}
                      when is_list(descendants) ->
                        # Build a lookup map from local ID -> AP URI
                        # Include the root post, ancestors, and descendants
                        all_statuses = [root_status | ancestors] ++ descendants

                        id_to_uri_map =
                          all_statuses
                          |> Enum.map(fn s -> {s["id"], s["uri"] || s["url"]} end)
                          |> Map.new()

                        # Convert Mastodon API statuses to ActivityPub-like objects
                        # with proper inReplyTo URIs
                        replies =
                          descendants
                          |> Enum.take(limit)
                          |> Enum.map(
                            &mastodon_status_to_activitypub(&1, id_to_uri_map, post_ap_id)
                          )
                          |> Enum.filter(&(&1 != nil))

                        Logger.debug(
                          "Fetched #{length(replies)} replies from context API for #{post_ap_id}"
                        )

                        {:ok, replies}

                      {:ok, %{"descendants" => descendants}} when is_list(descendants) ->
                        # Fallback if no ancestors field - use root post for mapping
                        id_to_uri_map = %{status_id => root_uri}

                        replies =
                          descendants
                          |> Enum.take(limit)
                          |> Enum.map(
                            &mastodon_status_to_activitypub(&1, id_to_uri_map, post_ap_id)
                          )
                          |> Enum.filter(&(&1 != nil))

                        {:ok, replies}

                      _ ->
                        {:ok, []}
                    end

                  {:error, reason} ->
                    Logger.warning(
                      "Failed to fetch context for #{post_ap_id}: #{inspect(reason)}"
                    )

                    {:ok, []}

                  _ ->
                    {:ok, []}
                end

              _ ->
                Logger.debug("Post not found in search: #{post_ap_id}")
                {:ok, []}
            end

          {:error, reason} ->
            Logger.warning("Failed to search for #{post_ap_id}: #{inspect(reason)}")
            {:ok, []}

          _ ->
            {:ok, []}
        end

      _ ->
        {:ok, []}
    end
  end

  # Convert a Mastodon API status to an ActivityPub-like object
  # id_to_uri_map maps local status IDs to their ActivityPub URIs
  # root_post_uri is the URI of the post we're fetching replies for
  defp mastodon_status_to_activitypub(status, id_to_uri_map, root_post_uri) do
    # Extract the ActivityPub URI if available
    ap_id = status["uri"] || status["url"]

    # Resolve inReplyTo: look up the parent's AP URI from the map
    # Fall back to akkoma/pleroma extensions, then to root post
    in_reply_to =
      cond do
        # Check Akkoma extension first (provides direct AP ID)
        ap_uri = get_in(status, ["akkoma", "in_reply_to_apid"]) ->
          ap_uri

        # Check Pleroma extension (note: in_reply_to_account_acct is the account, not the post)
        get_in(status, ["pleroma", "in_reply_to_account_acct"]) ->
          # This is the account acct, not the post URI - fall through to ID lookup
          nil

        # Look up from our ID map
        parent_id = status["in_reply_to_id"] ->
          Map.get(id_to_uri_map, parent_id)

        true ->
          nil
      end

    # If we couldn't resolve inReplyTo but we know there is one,
    # assume it's the root post (for direct replies)
    in_reply_to =
      if is_nil(in_reply_to) && status["in_reply_to_id"] do
        root_post_uri
      else
        in_reply_to
      end

    %{
      "id" => ap_id,
      "type" => "Note",
      "content" => status["content"],
      "published" => status["created_at"],
      "attributedTo" => get_in(status, ["account", "url"]) || get_in(status, ["account", "uri"]),
      "inReplyTo" => in_reply_to,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "sensitive" => status["sensitive"] || false,
      "summary" => status["spoiler_text"],
      # Store original API data for reference
      "_mastodon" => %{
        "id" => status["id"],
        "in_reply_to_id" => status["in_reply_to_id"],
        "account" => status["account"],
        "favourites_count" => status["favourites_count"],
        "reblogs_count" => status["reblogs_count"],
        "replies_count" => status["replies_count"]
      }
    }
  end

  # Fetch replies from standard ActivityPub collection
  defp fetch_replies_from_collection(replies_url, limit) do
    case Fetcher.fetch_object(replies_url) do
      {:ok, replies_data} ->
        {items, next_page} = extract_items_from_collection(replies_data)

        # If items is empty but there's a next page, fetch it
        {items, _} =
          if items == [] && next_page do
            case Fetcher.fetch_object(next_page) do
              {:ok, next_data} -> extract_items_from_collection(next_data)
              _ -> {[], nil}
            end
          else
            {items, next_page}
          end

        # Fetch full objects for URI-only items, then filter and extract reply objects
        replies =
          items
          |> Enum.take(limit)
          |> Enum.map(fn item ->
            case item do
              # Item is already a full object
              %{"type" => _type} = obj ->
                obj

              # Item is a Create activity - extract the object
              %{"object" => %{"type" => _} = obj} ->
                obj

              # Item is just a URI - fetch it
              uri when is_binary(uri) ->
                case Fetcher.fetch_object(uri) do
                  {:ok, fetched_obj} -> fetched_obj
                  _ -> nil
                end

              _ ->
                nil
            end
          end)
          |> Enum.filter(fn item ->
            case item do
              %{"type" => type} when type in ["Note", "Article", "Page"] -> true
              _ -> false
            end
          end)

        {:ok, replies}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Returns {items, next_page_url}
  defp extract_items_from_collection(collection_data) do
    case collection_data do
      %{"orderedItems" => items} when is_list(items) ->
        {items, collection_data["next"]}

      %{"items" => items} when is_list(items) ->
        {items, collection_data["next"]}

      %{"first" => %{"orderedItems" => items} = first} when is_list(items) ->
        {items, first["next"]}

      %{"first" => %{"items" => items} = first} when is_list(items) ->
        {items, first["next"]}

      _ ->
        {[], nil}
    end
  end

  # Group Follow functions

  alias Elektrine.ActivityPub.GroupFollow

  @doc """
  Creates a group follow relationship (remote actor following local Group).
  """
  def create_group_follow(remote_actor_id, group_actor_id, activitypub_id, pending \\ false) do
    %GroupFollow{}
    |> GroupFollow.changeset(%{
      remote_actor_id: remote_actor_id,
      group_actor_id: group_actor_id,
      activitypub_id: activitypub_id,
      pending: pending
    })
    |> Repo.insert()
  end

  @doc """
  Gets an existing group follow by remote actor and group actor.
  """
  def get_group_follow(remote_actor_id, group_actor_id) do
    Repo.get_by(GroupFollow, remote_actor_id: remote_actor_id, group_actor_id: group_actor_id)
  end

  @doc """
  Deletes a group follow relationship.
  """
  def delete_group_follow(remote_actor_id, group_actor_id) do
    case get_group_follow(remote_actor_id, group_actor_id) do
      nil -> {:ok, :not_found}
      follow -> Repo.delete(follow)
    end
  end

  @doc """
  Gets all followers (remote actors) of a local Group actor.
  Returns list of Actor structs with inbox_url.
  """
  def get_group_followers(group_actor_id) do
    from(gf in GroupFollow,
      where: gf.group_actor_id == ^group_actor_id and gf.pending == false,
      join: actor in assoc(gf, :remote_actor),
      select: actor
    )
    |> Repo.all()
  end

  @doc """
  Gets the inbox URLs for all followers of a local Group actor.
  Uses shared inbox when available.
  """
  def get_group_follower_inboxes(group_actor_id) do
    get_group_followers(group_actor_id)
    |> Enum.map(fn actor ->
      # Shared inbox is in metadata.endpoints.sharedInbox, not a direct field
      shared_inbox = get_in(actor.metadata || %{}, ["endpoints", "sharedInbox"])
      shared_inbox || actor.inbox_url
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @doc """
  Gets the count of followers for a local Group actor.
  """
  def get_group_follower_count(group_actor_id) do
    from(gf in GroupFollow,
      where: gf.group_actor_id == ^group_actor_id and gf.pending == false,
      select: count(gf.id)
    )
    |> Repo.one()
  end

  @doc """
  Gets a local Group actor by its URI.
  Returns nil if not found or not a Group.
  """
  def get_local_group_actor_by_uri(uri) do
    Repo.get_by(Actor,
      uri: uri,
      domain: instance_domain(),
      actor_type: "Group"
    )
  end
end
