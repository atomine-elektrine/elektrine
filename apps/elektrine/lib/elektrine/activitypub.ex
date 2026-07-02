defmodule Elektrine.ActivityPub do
  @moduledoc """
  The ActivityPub context for federation.
  Handles actors, activities, and federation with other instances.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Elektrine.Domains
  alias Elektrine.Repo

  alias Elektrine.ActivityPub.{
    Activity,
    ActivityDeliveryWorker,
    Actor,
    CollectionFetcher,
    Delivery,
    DomainDeliveryHealth,
    Fetcher,
    HTTPSignature,
    Instance,
    KeyManager,
    LemmyApi,
    LocalReferences,
    MastodonApi,
    MRF,
    ObjectDeliveries,
    RelaySubscription,
    RemoteFetch,
    ReplyFetchPolicy,
    RequestReplayCache,
    Tombstones,
    UserBlock
  }

  alias Elektrine.Accounts.User
  alias Elektrine.Async
  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.Security.URLValidator
  alias Elektrine.Social.Conversation
  alias Elektrine.Social.Conversations
  alias Elektrine.Telemetry.Events
  @public_audience_uri "https://www.w3.org/ns/activitystreams#Public"

  @doc """
  Fetches a single remote ActivityPub object for detail-page refresh paths.

  UI layers should call this context boundary instead of invoking fetch modules
  directly.
  """
  def fetch_remote_object_strict(uri) when is_binary(uri) do
    RemoteFetch.fetch_object_strict(uri)
  end

  def fetch_remote_object_strict(_), do: {:error, :invalid_activitypub_id}

  @doc """
  Fetches a remote ActivityPub object for interactive UI paths, allowing recovery
  through compatible instance APIs when the canonical object URL is not directly
  fetchable.
  """
  def fetch_remote_object(uri) when is_binary(uri) do
    RemoteFetch.fetch_object_uncached(uri)
  end

  def fetch_remote_object(_), do: {:error, :invalid_activitypub_id}

  @doc """
  Resolves a WebFinger handle through the federation fetch boundary.
  """
  def webfinger_lookup(acct, opts \\ []) do
    RemoteFetch.webfinger_lookup(acct, opts)
  end

  @doc """
  Gets the instance domain for this server.
  """
  def instance_domain do
    Elektrine.Domains.instance_domain()
  end

  @doc """
  Gets the instance base URL.
  """
  def instance_url do
    instance_url_for_domain(instance_domain())
  end

  @doc """
  Gets an instance-style base URL for a specific domain.
  """
  def instance_url_for_domain(domain) when is_binary(domain) do
    Domains.inferred_base_url_for_domain(domain)
  end

  @doc """
  Returns the canonical local ActivityPub identifier for a user.
  """
  def actor_identifier(%User{handle: handle, username: username}) do
    if Elektrine.Strings.present?(handle), do: handle, else: username
  end

  def actor_identifier(%{handle: handle, username: username}) do
    if Elektrine.Strings.present?(handle), do: handle, else: username
  end

  def actor_identifier(identifier) when is_binary(identifier) do
    identifier
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
  end

  def actor_identifier(_), do: nil

  @doc """
  Returns all local actor identifiers that should resolve for a user.

  The handle is canonical. The username remains as a compatibility alias.
  """
  def actor_identifiers(%User{} = user) do
    [actor_identifier(user), user.username]
    |> Enum.filter(&Elektrine.Strings.present?/1)
    |> Enum.uniq()
  end

  @doc """
  Returns the local ActivityPub actor URI for a user or explicit identifier.
  """
  def actor_uri(user_or_identifier, base_url \\ instance_url())

  def actor_uri(%User{} = user, base_url) do
    actor_uri(actor_identifier(user), base_url)
  end

  def actor_uri(identifier, base_url) when is_binary(identifier) and is_binary(base_url) do
    "#{String.trim_trailing(base_url, "/")}/users/#{actor_identifier(identifier)}"
  end

  def actor_uri(_, _), do: nil

  @doc """
  Returns the legacy username-based actor URI for a local user.
  """
  def actor_uri_by_username(user_or_identifier, base_url \\ instance_url())

  def actor_uri_by_username(%User{username: username}, base_url) when is_binary(username) do
    actor_uri(username, base_url)
  end

  def actor_uri_by_username(_, _), do: nil

  @doc """
  Returns the local ActivityPub key id for a user or explicit identifier.
  """
  def actor_key_id(user_or_identifier, base_url \\ instance_url())

  def actor_key_id(%User{} = user, base_url) do
    "#{actor_uri(user, base_url)}#main-key"
  end

  def actor_key_id(identifier, base_url) when is_binary(identifier) and is_binary(base_url) do
    "#{actor_uri(identifier, base_url)}#main-key"
  end

  def actor_key_id(_, _), do: nil

  @doc """
  Returns a local actor collection URI for a user.
  """
  def user_collection_uri(user_or_identifier, collection, base_url \\ instance_url())

  def user_collection_uri(%User{} = user, collection, base_url)
      when collection in ["inbox", "outbox", "followers", "following"] do
    "#{actor_uri(user, base_url)}/#{collection}"
  end

  def user_collection_uri(identifier, collection, base_url)
      when is_binary(identifier) and collection in ["inbox", "outbox", "followers", "following"] do
    "#{actor_uri(identifier, base_url)}/#{collection}"
  end

  def user_collection_uri(%User{} = user, collection, base_url) when is_atom(collection) do
    user_collection_uri(user, Atom.to_string(collection), base_url)
  end

  def user_collection_uri(identifier, collection, base_url)
      when is_binary(identifier) and is_atom(collection) do
    user_collection_uri(identifier, Atom.to_string(collection), base_url)
  end

  def user_collection_uri(_, _, _), do: nil

  @doc """
  Returns the local ActivityPub object URI for a user's status.
  """
  def user_status_uri(user_or_identifier, message_id, base_url \\ instance_url())

  def user_status_uri(%User{} = user, message_id, base_url) do
    "#{actor_uri(user, base_url)}/statuses/#{message_id}"
  end

  def user_status_uri(identifier, message_id, base_url)
      when is_binary(identifier) and is_binary(base_url) do
    "#{actor_uri(identifier, base_url)}/statuses/#{message_id}"
  end

  @doc """
  Returns the canonical ActivityPub slug for a local community.
  """
  def community_slug(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc """
  Returns the local ActivityPub actor URI for a community.
  """
  def community_actor_uri(name, base_url \\ instance_url()) when is_binary(name) do
    "#{String.trim_trailing(base_url, "/")}/c/#{community_slug(name)}"
  end

  @doc """
  Returns the inbox URI for a local community actor.
  """
  def community_inbox_uri(name, base_url \\ instance_url()) when is_binary(name) do
    "#{community_actor_uri(name, base_url)}/inbox"
  end

  @doc """
  Returns the outbox URI for a local community actor.
  """
  def community_outbox_uri(name, base_url \\ instance_url()) when is_binary(name) do
    "#{community_actor_uri(name, base_url)}/outbox"
  end

  @doc """
  Returns the followers collection URI for a local community actor.
  """
  def community_followers_uri(name, base_url \\ instance_url()) when is_binary(name) do
    "#{community_actor_uri(name, base_url)}/followers"
  end

  @doc """
  Returns the moderators collection URI for a local community actor.
  """
  def community_moderators_uri(name, base_url \\ instance_url()) when is_binary(name) do
    "#{community_actor_uri(name, base_url)}/moderators"
  end

  @doc """
  Returns the ActivityPub object URI for a local community post.
  """
  def community_post_uri(name, message_id, base_url \\ instance_url()) when is_binary(name) do
    "#{community_actor_uri(name, base_url)}/posts/#{message_id}"
  end

  @doc """
  Returns the HTML community page URL.
  """
  def community_web_url(name, base_url \\ instance_url()) when is_binary(name) do
    "#{String.trim_trailing(base_url, "/")}/communities/#{encode_path_segment(name)}"
  end

  @doc """
  Returns the HTML discussion post URL for a local community post.
  """
  def community_post_web_url(name, message_id, base_url \\ instance_url())
      when is_binary(name) do
    "#{community_web_url(name, base_url)}/post/#{message_id}"
  end

  @doc """
  Resolves a local community from either its stored name or its ActivityPub slug.
  """
  def get_community_by_identifier(identifier) when is_binary(identifier) do
    normalized_identifier =
      identifier
      |> String.trim()
      |> String.downcase()

    slug = community_slug(identifier)

    from(c in Conversation,
      where: c.type == "community",
      where:
        fragment("LOWER(?)", c.name) == ^normalized_identifier or
          fragment("regexp_replace(lower(?), '[^a-z0-9]+', '-', 'g')", c.name) == ^slug,
      order_by: [
        desc: fragment("LOWER(?) = ?", c.name, ^normalized_identifier)
      ],
      limit: 1,
      preload: [:creator]
    )
    |> Repo.one()
  end

  def get_community_by_identifier(_), do: nil

  defp encode_path_segment(segment) when is_binary(segment) do
    URI.encode(segment, &URI.char_unreserved?/1)
  end

  @doc """
  Returns local actor URI prefixes used to detect local `/users/:identifier` actor URLs.
  """
  def local_actor_prefixes do
    LocalReferences.actor_prefixes()
  end

  @doc """
  Resolves a local actor/profile URI to the owning user's username.

  Canonical actor URLs use handles, but legacy username-based URLs still resolve.
  """
  def local_username_from_uri(uri) when is_binary(uri) do
    LocalReferences.local_username_from_uri(uri)
  end

  def local_username_from_uri(uri), do: LocalReferences.local_username_from_uri(uri)

  @doc """
  Best-effort resolution of the local user targeted by an incoming activity.

  This is used for shared inbox processing so per-user moderation checks
  still apply even when the request did not hit `/users/:username/inbox`.
  """
  def resolve_target_user(activity) when is_map(activity) do
    LocalReferences.resolve_target_user(activity)
  end

  def resolve_target_user(activity), do: LocalReferences.resolve_target_user(activity)

  @doc """
  Best-effort resolution of the local user id targeted by an incoming activity.
  """
  def resolve_target_user_id(activity) when is_map(activity) do
    LocalReferences.resolve_target_user_id(activity)
  end

  def resolve_target_user_id(activity), do: LocalReferences.resolve_target_user_id(activity)

  ## Actors

  @doc """
  Gets or creates a remote actor by their URI.
  Fetches the actor document if not cached or stale.
  Uses in-memory caching to reduce database load during high traffic.
  """
  def get_or_fetch_actor(uri) do
    case normalize_actor_uri_input(uri) do
      normalized_uri when is_binary(normalized_uri) ->
        Elektrine.AppCache.get_actor(normalized_uri, fn ->
          do_get_or_fetch_actor(normalized_uri)
        end)

      _ ->
        {:error, :invalid_actor_uri}
    end
  end

  defp normalize_actor_uri_input(uri) when is_binary(uri) do
    case String.trim(uri) do
      "" -> nil
      normalized_uri -> normalized_uri
    end
  end

  defp normalize_actor_uri_input(values) when is_list(values) do
    Enum.find_value(values, &normalize_actor_uri_input/1)
  end

  defp normalize_actor_uri_input(value) when is_map(value) do
    value
    |> Map.take(["id", "url", "href", :id, :url, :href])
    |> Map.values()
    |> Enum.find_value(&normalize_actor_uri_input/1)
  end

  defp normalize_actor_uri_input(_), do: nil

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

   Returns the oldest actor if duplicates exist, so duplicate rows do not crash
   callers while the bad data is being cleaned up.
  """
  def get_actor_by_uri(uri) do
    from(a in Actor,
      where: a.uri == ^uri,
      order_by: [asc: a.inserted_at, asc: a.id],
      limit: 1
    )
    |> Repo.one()
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
  def fetch_and_cache_actor(uri, existing_actor_or_opts \\ nil)

  def fetch_and_cache_actor(uri, opts) when is_list(opts) do
    do_fetch_and_cache_actor(uri, nil, opts)
  end

  def fetch_and_cache_actor(uri, existing_actor) do
    do_fetch_and_cache_actor(uri, existing_actor, [])
  end

  defp do_fetch_and_cache_actor(uri, existing_actor, opts) do
    with {:ok, actor_data} <- RemoteFetch.fetch_actor(uri, opts),
         :ok <- validate_fetched_actor_identity(uri, actor_data),
         :ok <- validate_fetched_actor_urls(actor_data),
         {:ok, actor_data} <- apply_actor_policies(actor_data, uri),
         {:ok, actor} <- cache_actor(actor_data, existing_actor) do
      {:ok, actor}
    else
      {:reject, reason} ->
        Logger.info("MRF rejected actor document #{uri}: #{reason}")
        {:error, :mrf_rejected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_actor_policies(actor_data, _uri) when is_map(actor_data) do
    case MRF.filter(actor_data) do
      {:ok, filtered_actor_data} -> {:ok, filtered_actor_data}
      {:reject, reason} -> {:reject, reason}
    end
  end

  defp apply_actor_policies(actor_data, _uri), do: {:ok, actor_data}

  defp validate_fetched_actor_identity(uri, %{"id" => actor_id} = actor_data)
       when is_binary(uri) and is_binary(actor_id) and is_map(actor_data) do
    if actor_identity_matches?(uri, actor_id, actor_data) do
      :ok
    else
      Logger.warning(
        "Rejected fetched actor due to id mismatch: requested=#{inspect(uri)} returned=#{inspect(actor_id)}"
      )

      {:error, :actor_id_mismatch}
    end
  end

  defp validate_fetched_actor_identity(_uri, _actor_data), do: {:error, :actor_id_mismatch}

  defp actor_identity_matches?(requested_uri, actor_id, actor_data) when is_map(actor_data) do
    comparable_actor_uri(requested_uri) == comparable_actor_uri(actor_id) ||
      actor_username_alias_match?(requested_uri, actor_id, actor_data)
  end

  defp actor_username_alias_match?(requested_uri, actor_id, actor_data) do
    with %URI{host: requested_host} <- URI.parse(requested_uri),
         %URI{host: actor_host} <- URI.parse(actor_id),
         true <- is_binary(requested_host) and is_binary(actor_host),
         true <- String.downcase(requested_host) == String.downcase(actor_host),
         requested_username when is_binary(requested_username) <-
           actor_uri_username(requested_uri),
         fetched_username when is_binary(fetched_username) <- fetched_actor_username(actor_data) do
      String.downcase(requested_username) == String.downcase(fetched_username)
    else
      _ -> false
    end
  end

  defp actor_uri_username(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: "/users/" <> username} -> username |> String.split("/", parts: 2) |> List.first()
      %URI{path: "/@" <> username} -> username |> String.split("/", parts: 2) |> List.first()
      _ -> nil
    end
  end

  defp actor_uri_username(_), do: nil

  defp fetched_actor_username(actor_data) when is_map(actor_data) do
    actor_data["preferredUsername"] ||
      actor_data["preferred_username"] ||
      actor_data["name"]
  end

  defp fetched_actor_username(_), do: nil

  defp validate_fetched_actor_urls(actor_data) when is_map(actor_data) do
    actor_data
    |> actor_document_urls()
    |> Enum.reduce_while(:ok, fn {field, url}, :ok ->
      case URLValidator.validate(url) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning(
            "Rejected fetched actor due to unsafe #{field} URL #{inspect(url)}: #{inspect(reason)}"
          )

          {:halt, {:error, :unsafe_actor_document}}
      end
    end)
  end

  defp actor_document_urls(actor_data) do
    [
      {:id, actor_data["id"]},
      {:inbox, actor_data["inbox"]},
      {:outbox, actor_data["outbox"]},
      {:followers, actor_data["followers"]},
      {:following, actor_data["following"]},
      {:shared_inbox, get_in(actor_data, ["endpoints", "sharedInbox"])}
    ]
    |> Enum.filter(fn {_field, url} -> Elektrine.Strings.present?(url) end)
  end

  defp comparable_actor_uri(uri) when is_binary(uri) do
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

  defp comparable_actor_uri(_), do: nil

  defp cache_actor(actor_data, existing_actor) do
    uri = URI.parse(actor_data["id"])
    domain = uri.host

    # Ensure instance record exists
    get_or_create_instance(domain)

    # Extract and cache custom emojis from actor profile
    Async.start(fn ->
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

    actor = existing_actor || get_actor_by_username_and_domain(attrs.username, attrs.domain)

    upsert_cached_actor(actor, attrs)
  end

  defp upsert_cached_actor(%Actor{} = existing_actor, attrs) do
    attrs = merge_existing_actor_metadata(existing_actor, attrs)

    existing_actor
    |> Actor.changeset(attrs)
    |> Repo.update()
  end

  defp upsert_cached_actor(nil, attrs) do
    insert_opts = [
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :uri,
      returning: true
    ]

    case %Actor{} |> Actor.changeset(attrs) |> Repo.insert(insert_opts) do
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
        attrs = merge_existing_actor_metadata(existing_actor, attrs)

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

  defp merge_existing_actor_metadata(%Actor{} = existing_actor, attrs) when is_map(attrs) do
    existing_metadata = normalize_actor_metadata(existing_actor.metadata)
    incoming_metadata = normalize_actor_metadata(Map.get(attrs, :metadata))

    Map.put(attrs, :metadata, Map.merge(existing_metadata, incoming_metadata))
  end

  defp merge_existing_actor_metadata(_, attrs), do: attrs

  defp normalize_actor_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_actor_metadata(_), do: %{}

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

  defdelegate record_remote_delete_receipt(activity, actor_uri, object_id), to: Tombstones
  defdelegate record_remote_tombstone(activity, actor_uri, object_id), to: Tombstones
  defdelegate remote_delete_recorded?(actor_uri, object_refs), to: Tombstones
  defdelegate remote_tombstone_recorded?(actor_uri, object_refs), to: Tombstones

  @doc """
  Gets the most recent local activity for a user, type, and object.
  """
  def get_latest_local_activity(user_id, activity_type, object_id, opts \\ [])

  def get_latest_local_activity(_user_id, _activity_type, object_id, _opts)
      when not is_binary(object_id) do
    nil
  end

  def get_latest_local_activity(user_id, activity_type, object_id, opts) do
    content = Keyword.get(opts, :content)

    Activity
    |> where(
      [a],
      a.internal_user_id == ^user_id and a.local == true and a.activity_type == ^activity_type and
        a.object_id == ^object_id
    )
    |> maybe_filter_activity_content(content)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> limit(1)
    |> Repo.one()
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
    |> where_public_outbox_activity()
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
    |> where_public_outbox_activity()
    |> Repo.aggregate(:count, :id)
  end

  defp maybe_filter_activity_content(query, nil), do: query

  defp maybe_filter_activity_content(query, content) when is_binary(content) do
    where(query, [a], fragment("?->>'content' = ?", a.data, ^content))
  end

  defp where_public_outbox_activity(query) do
    where(
      query,
      [a],
      fragment(
        """
        jsonb_exists(COALESCE(?->'to', '[]'::jsonb), ?) OR
        jsonb_exists(COALESCE(?->'cc', '[]'::jsonb), ?) OR
        jsonb_exists(COALESCE(?->'object'->'to', '[]'::jsonb), ?) OR
        jsonb_exists(COALESCE(?->'object'->'cc', '[]'::jsonb), ?)
        """,
        a.data,
        ^@public_audience_uri,
        a.data,
        ^@public_audience_uri,
        a.data,
        ^@public_audience_uri,
        a.data,
        ^@public_audience_uri
      )
    )
  end

  ## Deliveries

  @doc """
  Creates delivery records for an activity to be sent to remote inboxes.
  Also enqueues Oban jobs for processing.
  """
  def create_deliveries(activity_id, inbox_urls) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    activity = Repo.get(Activity, activity_id)
    object_id = activity && (activity.object_id || object_id_from_activity_data(activity.data))

    record_object_deliveries(object_id, activity_id, inbox_urls)

    deliveries =
      inbox_urls
      |> deliverable_inboxes_for_activity(activity)
      |> Enum.map(fn inbox_url ->
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

  defp deliverable_inboxes_for_activity(inbox_urls, %Activity{activity_type: type})
       when type in ["Delete", "Update"] do
    Enum.uniq(inbox_urls)
  end

  defp deliverable_inboxes_for_activity(inbox_urls, _activity) do
    DomainDeliveryHealth.filter_deliverable_inboxes(inbox_urls)
  end

  defp object_id_from_activity_data(%{"object" => object}) when is_binary(object), do: object
  defp object_id_from_activity_data(%{"object" => %{"id" => id}}) when is_binary(id), do: id
  defp object_id_from_activity_data(_), do: nil

  defdelegate record_object_deliveries(object_id, activity_id, inbox_urls), to: ObjectDeliveries
  defdelegate get_object_delivery_inboxes(object_id), to: ObjectDeliveries

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
    started_at = System.monotonic_time(:millisecond)
    now = DateTime.utc_now()

    retryable_deliveries =
      Delivery
      |> where([d], d.status == "pending")
      |> where([d], is_nil(d.next_retry_at) or d.next_retry_at <= ^now)
      |> where([d], d.attempts < 10)
      |> order_by([d], asc: d.updated_at)
      |> limit(^limit)
      |> select([d], {d.id, d.inbox_url})
      |> Repo.all()

    delivery_ids =
      retryable_deliveries
      |> Enum.filter(fn {_id, inbox_url} -> DomainDeliveryHealth.deliverable_url?(inbox_url) end)
      |> Enum.map(fn {id, _inbox_url} -> id end)

    Events.db_hot_path(
      :activitypub,
      :get_retryable_delivery_ids,
      System.monotonic_time(:millisecond) - started_at,
      %{limit: limit, result_count: length(delivery_ids)}
    )

    delivery_ids
  end

  @doc """
  Marks a delivery as delivered.
  """
  def mark_delivery_delivered(delivery_id) do
    case Repo.get(Delivery, delivery_id) |> Repo.preload(:activity) do
      nil ->
        {:error, :not_found}

      delivery ->
        result =
          delivery
          |> Delivery.changeset(%{
            status: "delivered",
            last_attempt_at: DateTime.utc_now()
          })
          |> Repo.update()

        if match?({:ok, _}, result) do
          DomainDeliveryHealth.record_delivery_success(delivery.inbox_url)
          ObjectDeliveries.mark_object_delivery_delivered(delivery)
        end

        result
    end
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

    count + RequestReplayCache.prune_expired()
  end

  @doc """
  Marks a delivery as failed and schedules retry.
  """
  def mark_delivery_failed(delivery_id, error_message) do
    case Repo.get(Delivery, delivery_id) do
      nil ->
        {:error, :not_found}

      delivery ->
        DomainDeliveryHealth.record_delivery_failure(delivery.inbox_url, error_message)
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
  end

  ## Instances

  @doc """
  Gets or creates an instance record.
  """
  def get_or_create_instance(domain) do
    domain = normalize_instance_domain(domain)

    case get_instance_by_domain(domain) do
      nil ->
        %Instance{}
        |> Instance.changeset(%{domain: domain})
        |> Repo.insert()
        |> case do
          {:ok, instance} ->
            {:ok, instance}

          {:error, _changeset} ->
            case get_instance_by_domain(domain) do
              %Instance{} = instance -> {:ok, instance}
              nil -> {:error, :instance_insert_failed}
            end
        end

      instance ->
        {:ok, instance}
    end
  end

  @doc """
  Checks if an instance is blocked.
  """
  def instance_blocked?(domain) do
    case get_instance_by_domain(domain) do
      %Instance{blocked: true} -> true
      _ -> false
    end
  end

  defp get_instance_by_domain(domain) when is_binary(domain) do
    normalized = normalize_instance_domain(domain)

    Instance
    |> where([i], fragment("lower(?)", i.domain) == ^normalized)
    |> order_by([i], asc: i.id)
    |> limit(1)
    |> Repo.one()
  end

  defp get_instance_by_domain(_), do: nil

  defp normalize_instance_domain(domain) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_instance_domain(domain), do: domain

  @doc """
  Blocks an instance.
  """
  def block_instance(domain, reason, admin_user_id) do
    case get_or_create_instance(domain) do
      {:ok, instance} ->
        result =
          instance
          |> Instance.changeset(%{
            blocked: true,
            reason: reason,
            blocked_by_id: admin_user_id,
            blocked_at: DateTime.utc_now()
          })
          |> Repo.update()

        notify_all_home_feeds(:instance_blocked)
        result

      error ->
        error
    end
  end

  ## User blocks

  @doc """
  Blocks a remote actor or domain for a specific user.
  """
  def block_for_user(user_id, blocked_uri, type \\ "user") do
    result =
      %UserBlock{}
      |> UserBlock.changeset(%{
        user_id: user_id,
        blocked_uri: blocked_uri,
        block_type: type
      })
      |> Repo.insert()

    notify_home_feed_policy_changed(user_id, :activitypub_blocked)
    result
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

  @doc """
  Returns true when the actor URI belongs to an accepted relay subscription.
  """
  def active_relay_actor_uri?(actor_uri) when is_binary(actor_uri) do
    RelaySubscription
    |> where([s], s.relay_uri == ^actor_uri and s.status == "active" and s.accepted == true)
    |> Repo.exists?()
  end

  def active_relay_actor_uri?(_), do: false

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
    community_slug = community_slug(community.name)
    actor_url = community_actor_uri(community.name, base_url)
    {public_key, private_key} = HTTPSignature.generate_key_pair()

    attrs = %{
      uri: actor_url,
      username: community_slug,
      domain: instance_domain(),
      display_name: community.name,
      summary: community.description,
      avatar_url: community.avatar_url,
      inbox_url: community_inbox_uri(community.name, base_url),
      outbox_url: community_outbox_uri(community.name, base_url),
      followers_url: community_followers_uri(community.name, base_url),
      moderators_url: community_moderators_uri(community.name, base_url),
      public_key: public_key,
      manually_approves_followers: !community.is_public,
      actor_type: "Group",
      community_id: community.id,
      published_at: community.inserted_at,
      last_fetched_at: DateTime.utc_now(),
      metadata: Actor.put_metadata_private_key(%{}, private_key)
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
    community_slug = community_slug(name)

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
    fetcher = Keyword.get(opts, :fetcher, Fetcher)

    case Repo.get(Actor, remote_actor_id) do
      nil ->
        {:error, :actor_not_found}

      %Actor{outbox_url: nil} ->
        {:error, :no_outbox_url}

      %Actor{outbox_url: outbox_url} ->
        case fetcher.fetch_object(outbox_url) do
          {:ok, outbox_data} ->
            posts = extract_posts_from_outbox(outbox_data, limit, fetcher)
            {:ok, posts}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp extract_posts_from_outbox(outbox_data, limit, fetcher) do
    outbox_data
    |> collect_outbox_items(limit, fetcher)
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
          case fetcher.fetch_object(object_url) do
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
          case fetcher.fetch_object(url) do
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

  defp collect_outbox_items(outbox_data, limit, fetcher) do
    {items, next_page_url} = extract_outbox_page(outbox_data)

    if length(items) >= limit or is_nil(next_page_url) do
      items
    else
      collect_next_outbox_items(items, next_page_url, limit, fetcher, MapSet.new())
    end
  end

  defp collect_next_outbox_items(items, _next_page_url, limit, _fetcher, _visited_urls)
       when length(items) >= limit,
       do: items

  defp collect_next_outbox_items(items, nil, _limit, _fetcher, _visited_urls), do: items

  defp collect_next_outbox_items(items, next_page_url, limit, fetcher, visited_urls) do
    if MapSet.member?(visited_urls, next_page_url) do
      items
    else
      visited_urls = MapSet.put(visited_urls, next_page_url)

      case fetcher.fetch_object(next_page_url) do
        {:ok, page} ->
          {page_items, following_page_url} = extract_outbox_page(page)
          combined_items = items ++ page_items

          if length(combined_items) >= limit or is_nil(following_page_url) do
            combined_items
          else
            collect_next_outbox_items(
              combined_items,
              following_page_url,
              limit,
              fetcher,
              visited_urls
            )
          end

        _ ->
          items
      end
    end
  end

  defp extract_outbox_page(outbox_data) do
    case outbox_data do
      %{"orderedItems" => items} when is_list(items) ->
        {items, outbox_data["next"]}

      %{"items" => items} when is_list(items) ->
        {items, outbox_data["next"]}

      # Handle first as a URL string
      %{"first" => first_page_url} when is_binary(first_page_url) ->
        {[], first_page_url}

      # Handle first as an object with id
      %{"first" => %{"id" => first_page_url}} when is_binary(first_page_url) ->
        {[], first_page_url}

      # Handle first as an object with items directly
      %{"first" => %{"orderedItems" => items} = first} when is_list(items) ->
        {items, first["next"]}

      %{"first" => %{"items" => items} = first} when is_list(items) ->
        {items, first["next"]}

      _ ->
        {[], nil}
    end
  end

  @doc """
  Fetches replies for a remote post.
  Returns a list of reply objects.
  """
  def fetch_remote_post_replies(post_object, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 10) |> ReplyFetchPolicy.clamp_collection_limit()
    post_id = post_object["id"]
    post_url = post_object["url"] || post_id

    # Link posts often use the external article URL as object.url. Keep using that for
    # rendering, but use the ActivityPub/community post URL when deciding how to load
    # comments so Lemmy-style replies aren't fetched from the submitted link target.
    community_post_ref =
      cond do
        lemmy_post_url?(post_id) -> post_id
        lemmy_post_url?(post_url) -> post_url
        true -> post_id || post_url
      end

    lemmy_post? = post_object["type"] == "Page" && lemmy_post_url?(community_post_ref)

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
    post_id = post_id || post_url

    cond do
      # Lemmy community posts are more reliably served by the instance API than the
      # AP replies collection, which is often empty or requires extra indirection.
      lemmy_post? ->
        case fetch_lemmy_comments(community_post_ref, limit) do
          {:ok, replies} when replies != [] ->
            {:ok, replies}

          _ when replies_url != nil ->
            fetch_replies_from_collection(replies_url, limit, community_post_ref)

          other ->
            other
        end

      # Standard ActivityPub replies collection
      replies_url != nil ->
        case fetch_replies_from_collection(replies_url, limit, post_id || post_url) do
          {:ok, replies} when replies != [] ->
            {:ok, replies}

          other ->
            # ActivityPub collection returned empty but we expect replies - try
            # Mastodon-compatible context endpoints when the post URL supports them.
            if expected_replies > 0 and is_binary(post_url) and
                 MastodonApi.mastodon_compatible?(%{activitypub_id: post_url}) do
              fetch_mastodon_context_replies(post_url, limit)
            else
              other
            end
        end

      # Has replies count but no replies field - try Mastodon-compatible context APIs.
      has_replies_count && is_binary(post_url) &&
          MastodonApi.mastodon_compatible?(%{activitypub_id: post_url}) ->
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
          |> supplement_mastodon_thread_replies(post_url, limit)
          |> ReplyFetchPolicy.filter_same_host_replies(post_url)

        {:ok, replies}

      {:error, _} ->
        {:ok, []}
    end
  end

  defp supplement_mastodon_thread_replies(replies, _post_url, limit)
       when not is_list(replies) or limit <= 0 do
    Enum.take(List.wrap(replies), max(limit, 0))
  end

  defp supplement_mastodon_thread_replies(replies, post_url, limit) do
    seen_ids =
      replies
      |> Enum.map(& &1["id"])
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    additional_replies =
      [post_url | replies]
      |> collect_supplemental_thread_replies(limit, seen_ids, [])
      |> ReplyFetchPolicy.filter_same_host_replies(post_url)

    merge_unique_replies(replies, additional_replies, limit)
  end

  defp collect_supplemental_thread_replies([], _limit, _seen_ids, acc), do: Enum.reverse(acc)

  defp collect_supplemental_thread_replies(_queue, limit, _seen_ids, acc)
       when length(acc) >= limit do
    acc |> Enum.reverse() |> Enum.take(limit)
  end

  defp collect_supplemental_thread_replies([seed | rest], limit, seen_ids, acc) do
    remaining = max(limit - length(acc), 0)

    case fetch_thread_seed_object(seed) do
      %{"replies" => replies_collection} when not is_nil(replies_collection) ->
        fetched_replies = fetch_supplemental_reply_page(replies_collection, remaining)

        {fresh_replies, updated_seen_ids} =
          Enum.reduce(fetched_replies, {[], seen_ids}, fn reply, {fresh, seen} ->
            case reply["id"] do
              id when is_binary(id) ->
                if MapSet.member?(seen, id) do
                  {fresh, seen}
                else
                  {[reply | fresh], MapSet.put(seen, id)}
                end

              _ ->
                {[reply | fresh], seen}
            end
          end)

        fresh_replies = Enum.reverse(fresh_replies)

        next_queue =
          rest ++
            Enum.filter(fresh_replies, fn reply ->
              reply_has_nested_replies?(reply)
            end)

        collect_supplemental_thread_replies(
          next_queue,
          limit,
          updated_seen_ids,
          fresh_replies ++ acc
        )

      %{} = object ->
        next_queue = if(reply_has_nested_replies?(object), do: rest ++ [object], else: rest)
        collect_supplemental_thread_replies(next_queue, limit, seen_ids, acc)

      _ ->
        collect_supplemental_thread_replies(rest, limit, seen_ids, acc)
    end
  end

  defp fetch_thread_seed_object(%{} = object), do: normalize_thread_reply_object(object)

  defp fetch_thread_seed_object(seed) when is_binary(seed) do
    case RemoteFetch.fetch_object(seed) do
      {:ok, object} -> normalize_thread_reply_object(object)
      _ -> nil
    end
  end

  defp fetch_thread_seed_object(_), do: nil

  defp normalize_thread_reply_object(%{"type" => type} = object)
       when type in ["Note", "Article", "Page", "Question"] do
    object
  end

  defp normalize_thread_reply_object(%{"object" => %{} = object}) do
    normalize_thread_reply_object(object)
  end

  defp normalize_thread_reply_object(_), do: nil

  defp fetch_supplemental_reply_page(replies_collection, limit) when limit > 0 do
    case CollectionFetcher.fetch_collection(replies_collection, max_items: limit) do
      {:ok, items} -> normalize_thread_reply_items(items, limit)
      {:partial, items} -> normalize_thread_reply_items(items, limit)
      _ -> []
    end
  end

  defp fetch_supplemental_reply_page(_, _), do: []

  defp normalize_thread_reply_items(items, limit) do
    items
    |> Enum.map(&normalize_thread_reply_object/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(limit)
  end

  defp reply_has_nested_replies?(%{} = reply) do
    replies = reply["replies"]

    cond do
      is_map(replies) -> true
      is_binary(replies) -> true
      true -> Elektrine.ActivityPub.Helpers.extract_interaction_count(reply, "replies") > 0
    end
  end

  defp reply_has_nested_replies?(_), do: false

  defp merge_unique_replies(primary, secondary, limit) do
    {merged, _seen} =
      Enum.reduce(primary ++ secondary, {[], MapSet.new()}, fn reply, {acc, seen} ->
        case reply["id"] do
          id when is_binary(id) ->
            if MapSet.member?(seen, id) do
              {acc, seen}
            else
              {[reply | acc], MapSet.put(seen, id)}
            end

          _ ->
            {[reply | acc], seen}
        end
      end)

    merged
    |> Enum.reverse()
    |> Enum.take(limit)
  end

  # Check if URL is a community-post format across Lemmy/PieFed/Mbin.
  defp lemmy_post_url?(url) when is_binary(url) do
    LemmyApi.community_post_url?(url)
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
        resolve_url = "https://#{domain}/api/v4/resolve_object?q=#{URI.encode_www_form(post_url)}"

        case safe_get_lemmy_api(resolve_url, [{"Accept", "application/json"}],
               receive_timeout: 10_000
             ) do
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
    case RemoteFetch.fetch_object(post_url) do
      {:ok, post_object} ->
        # Get the community URL from audience field
        community_url = post_object["audience"]

        if is_binary(community_url) do
          # Extract community's home domain
          case URI.parse(community_url) do
            %URI{host: community_domain} when is_binary(community_domain) ->
              # Resolve the post on the community's home instance
              resolve_url =
                "https://#{community_domain}/api/v4/resolve_object?q=#{URI.encode_www_form(post_url)}"

              case safe_get_lemmy_api(resolve_url, [{"Accept", "application/json"}],
                     receive_timeout: 10_000
                   ) do
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
    replies = LemmyApi.fetch_post_comments_from_instance(domain, post_id, post_url, limit)

    {:ok, replies}
  end

  # Fetch replies using context API (Mastodon/Pleroma/Akkoma)
  defp fetch_pleroma_replies(post_ap_id, limit) do
    require Logger

    # Extract domain from the ActivityPub ID
    case URI.parse(post_ap_id) do
      %URI{host: domain} when is_binary(domain) ->
        # Step 1: Search for the post to get its internal ID
        search_url =
          "https://#{domain}/api/v2/search?q=#{URI.encode_www_form(post_ap_id)}&type=statuses&resolve=true&limit=1"

        case safe_get(search_url, [{"Accept", "application/json"}], receive_timeout: 15_000) do
          {:ok, %Finch.Response{status: 200, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"statuses" => [%{"id" => status_id, "uri" => root_uri} = root_status | _]}} ->
                # Step 2: Fetch context (ancestors + descendants)
                context_url = "https://#{domain}/api/v1/statuses/#{status_id}/context"

                case safe_get(context_url, [{"Accept", "application/json"}],
                       receive_timeout: 15_000
                     ) do
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
  defp fetch_replies_from_collection(replies_url, limit, root_ref) do
    case RemoteFetch.fetch_object(replies_url) do
      {:ok, replies_data} ->
        {items, next_page} = extract_items_from_collection(replies_data)

        # If items is empty but there's a next page, fetch it
        {items, _} =
          if items == [] && next_page do
            case RemoteFetch.fetch_object(next_page) do
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
                case RemoteFetch.fetch_object(uri) do
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
          |> ReplyFetchPolicy.filter_same_host_replies(root_ref)

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
    from(a in Actor,
      join: c in Conversation,
      on: c.id == a.community_id,
      where: a.uri == ^uri and a.domain == ^instance_domain() and a.actor_type == "Group",
      where: c.type == "community" and c.is_public == true
    )
    |> Repo.one()
  end

  defp safe_get(url, headers, opts) do
    request = Finch.build(:get, url, headers)
    SafeFetch.request(request, Elektrine.Finch, opts)
  end

  defp safe_get_lemmy_api(url, headers, opts) do
    case safe_get(url, headers, opts) do
      {:ok, %Finch.Response{status: 404}} ->
        url
        |> fallback_lemmy_api_url()
        |> case do
          nil -> {:ok, %Finch.Response{status: 404, headers: [], body: ""}}
          fallback_url -> safe_get(fallback_url, headers, opts)
        end

      other ->
        other
    end
  end

  defp fallback_lemmy_api_url(url) when is_binary(url) do
    if String.contains?(url, "/api/v4/") do
      String.replace(url, "/api/v4/", "/api/v3/", global: false)
    else
      nil
    end
  end

  defp fallback_lemmy_api_url(_), do: nil

  defp notify_home_feed_policy_changed(user_id, reason) when is_integer(user_id) do
    module = Module.concat([Elektrine, Social, HomeFeedInvalidationWorker])

    if Code.ensure_loaded?(module) do
      _ = module.clear_user(user_id, reason)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp notify_all_home_feeds(reason) do
    module = Module.concat([Elektrine, Social, HomeFeed])

    if Code.ensure_loaded?(module) do
      _ = module.clear_all(reason)
    end

    :ok
  rescue
    _ -> :ok
  end
end
