defmodule Elektrine.Messaging.Federation do
  @moduledoc "Lightweight federation support for Discord-style messaging servers.\n\nThis module now supports both:\n- snapshot sync (coarse-grained)\n- real-time event sync with per-stream sequencing and idempotency\n- optional relay-routed transport for outbound HTTP federation traffic\n"
  import Ecto.Query, warn: false
  import Elektrine.Messaging.Federation.Utils
  require Logger
  alias Elektrine.Async
  alias Elektrine.Messaging.Federation.Config

  alias Elektrine.Messaging.{
    ArblargProfiles,
    ArblargSDK,
    ChatMessage,
    ChatMessageReaction,
    ChatMessages,
    Conversation,
    ConversationMember,
    Federation.PeerPolicies,
    FederationEvent,
    FederationExtensionEvent,
    FederationOutboxEvent,
    FederationOutboxWorker,
    FederationPresenceState,
    FederationReadReceipt,
    FederationRequestReplay,
    FederationStreamPosition,
    Server
  }

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor, as: ActivityPubActor
  alias Elektrine.Notifications
  alias Elektrine.PubSubTopics

  alias Elektrine.Repo
  @clock_skew_seconds ArblargSDK.clock_skew_seconds()
  @bootstrap_server_upsert_event_type ArblargSDK.bootstrap_server_upsert_event_type()
  @dm_message_create_event_type ArblargSDK.dm_message_create_event_type()
  @role_upsert_event_type ArblargSDK.canonical_event_type("role.upsert")
  @role_assignment_upsert_event_type ArblargSDK.canonical_event_type("role.assignment.upsert")
  @permission_overwrite_upsert_event_type ArblargSDK.canonical_event_type(
                                            "permission.overwrite.upsert"
                                          )
  @thread_upsert_event_type ArblargSDK.canonical_event_type("thread.upsert")
  @thread_archive_event_type ArblargSDK.canonical_event_type("thread.archive")
  @presence_update_event_type ArblargSDK.canonical_event_type("presence.update")
  @moderation_action_recorded_event_type ArblargSDK.canonical_event_type(
                                           "moderation.action.recorded"
                                         )
  @remote_dm_source_prefix "arbp:dm:"
  @discord_extension_event_types ArblargSDK.roles_event_types() ++
                                   ArblargSDK.permissions_event_types() ++
                                   ArblargSDK.threads_event_types() ++
                                   ArblargSDK.presence_event_types() ++
                                   ArblargSDK.moderation_event_types()

  @doc "Returns true when messaging federation is enabled.\n"
  def enabled? do
    federation_config() |> Keyword.get(:enabled, false)
  end

  @doc "Returns normalized peer configs.\n"
  def peers do
    configured_peers()
    |> PeerPolicies.apply_runtime_policies()
  end

  @doc "Returns the peer config for incoming requests by domain.\n"
  def incoming_peer(domain) when is_binary(domain) do
    normalized = String.downcase(domain)

    Enum.find(peers(), fn peer ->
      peer.allow_incoming and String.downcase(peer.domain) == normalized
    end)
  end

  @doc "Returns outgoing-enabled peers.\n"
  def outgoing_peers do
    Enum.filter(peers(), & &1.allow_outgoing)
  end

  @doc "Returns the outgoing-enabled peer config for a specific domain.\n"
  def outgoing_peer(domain) when is_binary(domain) do
    normalized = String.downcase(String.trim(domain))

    Enum.find(outgoing_peers(), fn peer ->
      String.downcase(peer.domain) == normalized
    end)
  end

  def outgoing_peer(_), do: nil

  @doc "Returns the local messaging federation domain.\n"
  def local_domain do
    configured =
      federation_config()
      |> Keyword.get(:local_domain)
      |> normalize_optional_string()
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    configured ||
      System.get_env("INSTANCE_DOMAIN")
      |> normalize_optional_string()
      |> case do
        nil -> "z.org"
        domain -> String.downcase(domain)
      end
  end

  @doc "Lists current federated presence states for a mirror server.\n"
  def list_server_presence_states(server_id) when is_integer(server_id) do
    from(state in FederationPresenceState,
      where: state.server_id == ^server_id,
      join: actor in ActivityPubActor,
      on: actor.id == state.remote_actor_id,
      order_by: [desc: state.updated_at_remote],
      select: %{
        remote_actor_id: actor.id,
        username: actor.username,
        display_name: actor.display_name,
        domain: actor.domain,
        avatar_url: actor.avatar_url,
        status: state.status,
        activities: state.activities,
        updated_at: state.updated_at_remote
      }
    )
    |> Repo.all()
    |> Enum.map(fn state ->
      %{
        remote_actor_id: state.remote_actor_id,
        handle: "@#{state.username}@#{state.domain}",
        label:
          case normalize_optional_string(state.display_name) do
            nil -> "@#{state.username}@#{state.domain}"
            display_name -> "#{display_name} (@#{state.username}@#{state.domain})"
          end,
        avatar_url: state.avatar_url,
        status: state.status,
        activities: normalize_presence_activities(state.activities),
        updated_at: state.updated_at
      }
    end)
  end

  def list_server_presence_states(_server_id), do: []

  @doc "Lists runtime messaging federation peer controls for admin tooling.\n"
  def list_peer_controls do
    configured_peers()
    |> PeerPolicies.list_peer_controls()
  end

  @doc "Creates or updates a runtime peer policy override for a domain.\n"
  def upsert_peer_policy(domain, attrs, updated_by_id \\ nil) when is_map(attrs) do
    PeerPolicies.upsert_peer_policy(domain, attrs, updated_by_id)
  end

  @doc "Removes any runtime peer policy override for a domain.\n"
  def clear_peer_policy(domain) do
    PeerPolicies.clear_peer_policy(domain)
  end

  @doc "Blocks a peer domain for both incoming and outgoing federation traffic.\n"
  def block_peer_domain(domain, reason \\ nil, updated_by_id \\ nil) do
    PeerPolicies.block_peer_domain(domain, reason, updated_by_id)
  end

  @doc "Unblocks a peer domain and clears directional runtime overrides.\n"
  def unblock_peer_domain(domain, updated_by_id \\ nil) do
    PeerPolicies.unblock_peer_domain(domain, updated_by_id)
  end

  @doc "Public discovery document for cross-domain federation bootstrap.\n"
  def local_discovery_document(version \\ ArblargSDK.protocol_version()) do
    %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_labels" => [ArblargSDK.protocol_label()],
      "default_protocol_label" => ArblargSDK.protocol_label(),
      "protocol_versions" => [ArblargSDK.protocol_version()],
      "default_protocol_version" => ArblargSDK.protocol_version(),
      "version" => 1,
      "domain" => local_domain(),
      "identity" => local_identity_discovery_identity(),
      "endpoints" => discovery_endpoints(version),
      "features" => %{
        "relay_transport" => true
      },
      "relay_transport" => %{
        "mode" => "optional",
        "community_hostable" => true,
        "official_operator" => official_relay_operator(),
        "official_relays" => discovery_official_relays()
      }
    }
  end

  @doc "Returns profile and extension badge metadata for ARBP.\n"
  def arblarg_profiles_document(version \\ ArblargSDK.protocol_version()) do
    clock_skew_seconds = clock_skew_seconds()
    core_event_types = ArblargProfiles.core_event_types()
    extension_event_types = ArblargProfiles.extension_event_types()
    supported_event_types = ArblargSDK.supported_event_types()

    %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_versions" => [ArblargSDK.protocol_version()],
      "default_protocol_version" => ArblargSDK.protocol_version(),
      "version" => 1,
      "profiles" => ArblargProfiles.profile_badges(),
      "compatibility_claims" => ArblargProfiles.passing_profile_claims(),
      "extensions" => ArblargProfiles.extension_registry(),
      "features" => %{
        "event_federation" => true,
        "snapshot_sync" => true,
        "ordered_streams" => true,
        "idempotent_events" => true,
        "relay_transport" => true,
        "event_signature_envelope" => true,
        "request_replay_protection" => true,
        "strict_profiles" => true,
        "extension_negotiation" => true,
        "wire_contract_frozen" => true
      },
      "security" => %{
        "request_signature" => %{
          "algorithm" => ArblargSDK.signature_algorithm(),
          "required" => true,
          "headers" => [
            "x-elektrine-federation-domain",
            "x-elektrine-federation-key-id",
            "x-elektrine-federation-timestamp",
            "x-elektrine-federation-content-digest",
            "x-arblarg-request-id",
            "x-arblarg-signature-algorithm",
            "x-elektrine-federation-signature"
          ],
          "clock_skew_seconds" => clock_skew_seconds
        },
        "event_signature" => %{
          "algorithm" => ArblargSDK.signature_algorithm(),
          "field" => "signature",
          "required" => true
        },
        "transport" => %{
          "tls_required" => true,
          "allow_insecure_http_for_testing" => allow_insecure_transport?()
        }
      },
      "events" => %{
        "core" => core_event_types,
        "extensions" => extension_event_types,
        "supported" => supported_event_types,
        "ordering" => %{
          "cursor" => %{"field" => "sequence", "scope" => ["origin_domain", "stream_id"]},
          "idempotency" => %{"field" => "idempotency_key", "scope" => ["origin_domain"]},
          "retry" => %{"strategy" => "bounded_exponential_backoff", "deterministic" => true}
        }
      },
      "schemas" => discovery_schema_map(version),
      "relay_transport" => %{
        "mode" => "optional",
        "community_hostable" => true,
        "official_operator" => official_relay_operator(),
        "official_relays" => discovery_official_relays()
      },
      "wire_contract" => %{
        "status" => "frozen",
        "breaking_changes" => "forbidden_after_1_0",
        "change_policy" => "additive_only",
        "deprecation_policy" => "minimum_two_minor_releases"
      },
      "endpoints" => discovery_endpoints(version),
      "conformance" => %{
        "gate" => "hard",
        "suite_version" => ArblargProfiles.conformance_suite_version(),
        "required_profile" => ArblargProfiles.core_profile_id(),
        "test_command" => ArblargProfiles.conformance_test_command()
      }
    }
  end

  defp discovery_endpoints(version) do
    base_url = local_base_url()

    %{
      "well_known" => "#{base_url}/.well-known/arblarg",
      "well_known_versioned" => "#{base_url}/.well-known/arblarg/{version}",
      "profiles" => "#{base_url}/federation/messaging/arblarg/profiles",
      "events" => "#{base_url}/federation/messaging/events",
      "sync" => "#{base_url}/federation/messaging/sync",
      "public_servers" => "#{base_url}/federation/messaging/servers/public",
      "snapshot_template" => "#{base_url}/federation/messaging/servers/{server_id}/snapshot",
      "schema_template" => "#{base_url}/federation/messaging/arblarg/{version}/schemas/{name}",
      "schemas" => "#{base_url}/federation/messaging/arblarg/#{version}/schemas"
    }
  end

  defp discovery_schema_map(version) do
    schema_base = "#{local_base_url()}/federation/messaging/arblarg/#{version}/schemas"

    schema_links =
      ArblargSDK.schema_bindings()
      |> Enum.reduce(%{}, fn {schema_key, schema_name}, acc ->
        Map.put(acc, schema_key, "#{schema_base}/#{schema_name}")
      end)

    Map.merge(%{"version" => version, "base_url" => schema_base}, schema_links)
  end

  @doc "Builds the canonical string that gets signed for federation requests.\n"
  def signature_payload(
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest \\ "",
        request_id \\ ""
      ) do
    ArblargSDK.canonical_request_signature_payload(
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      request_id
    )
  end

  @doc "Computes the URL-safe base64 SHA-256 digest for a request body.\n"
  def body_digest(body) when is_binary(body) do
    ArblargSDK.body_digest(body)
  end

  def body_digest(_) do
    body_digest("")
  end

  @doc "Signs a payload with Ed25519.\n"
  def sign_payload(payload, signing_material) when is_binary(payload) do
    ArblargSDK.sign_payload(payload, signing_material)
  end

  @doc "Validates timestamp freshness.\n"
  def valid_timestamp?(timestamp) when is_binary(timestamp) do
    ArblargSDK.valid_timestamp?(timestamp, clock_skew_seconds())
  end

  @doc "Verifies an incoming signature for the request using a raw secret.\n"
  def verify_signature(secret, domain, method, request_path, query_string, timestamp, signature)
      when is_binary(secret) and is_binary(signature) do
    verify_signature(
      secret,
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      "",
      "",
      signature
    )
  end

  @doc "Verifies an incoming signature using a normalized peer config and optional key id.\nSupports key rotation by accepting any configured incoming key for the peer.\n"
  def verify_signature(
        secret,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        signature
      )
      when is_binary(secret) and is_binary(signature) do
    verify_signature(
      secret,
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      "",
      signature
    )
  end

  def verify_signature(
        peer,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        key_id,
        signature
      )
      when is_map(peer) and is_binary(signature) do
    verify_signature(
      peer,
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      "",
      "",
      key_id,
      signature
    )
  end

  def verify_signature(
        secret,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id,
        signature
      )
      when is_binary(secret) and is_binary(signature) do
    payload =
      signature_payload(
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id
      )

    ArblargSDK.verify_payload_signature(payload, secret, signature)
  end

  def verify_signature(
        peer,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        key_id,
        signature
      )
      when is_map(peer) and is_binary(signature) do
    verify_signature(
      peer,
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      "",
      key_id,
      signature
    )
  end

  def verify_signature(
        peer,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id,
        key_id,
        signature
      )
      when is_map(peer) and is_binary(signature) do
    peer
    |> incoming_verification_materials_for_key_id(key_id)
    |> Enum.any?(fn public_key_material ->
      verify_signature(
        public_key_material,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id,
        signature
      )
    end)
  end

  @doc "Builds headers for an outgoing signed federation request.\n"
  def signed_headers(peer, method, request_path, query_string \\ "", body \\ "") do
    timestamp = Integer.to_string(System.system_time(:second))
    domain = local_domain()
    request_id = Ecto.UUID.generate()
    {key_id, signing_material} = outbound_signing_material(peer)
    content_digest = body_digest(body)

    signature =
      signature_payload(
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id
      )
      |> sign_payload(signing_material)

    [
      {"content-type", "application/json"},
      {"x-elektrine-federation-domain", domain},
      {"x-elektrine-federation-key-id", key_id},
      {"x-elektrine-federation-timestamp", timestamp},
      {"x-elektrine-federation-content-digest", content_digest},
      {"x-arblarg-request-id", request_id},
      {"x-arblarg-signature-algorithm", ArblargSDK.signature_algorithm()},
      {"x-elektrine-federation-signature", signature}
    ]
  end

  @doc "Returns deterministic replay nonce for incoming signed requests.\n"
  def request_replay_nonce(
        domain,
        key_id,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id,
        signature
      ) do
    base =
      [
        to_string(domain || "") |> String.downcase(),
        to_string(key_id || ""),
        to_string(method || "") |> String.upcase(),
        canonical_path(request_path),
        canonical_query_string(query_string),
        to_string(timestamp || "") |> String.trim(),
        canonical_content_digest(content_digest),
        to_string(request_id || "") |> String.trim(),
        to_string(signature || "") |> String.trim()
      ]
      |> Enum.join("\n")

    :crypto.hash(:sha256, base) |> Base.url_encode64(padding: false)
  end

  @doc "Claims an incoming signed request nonce for replay protection.\n"
  def claim_request_nonce(
        domain,
        key_id,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id,
        signature
      ) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, replay_nonce_ttl_seconds(), :second)

    nonce =
      request_replay_nonce(
        domain,
        key_id,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id,
        signature
      )

    inserted_at = DateTime.to_naive(now)

    attrs = [
      %{
        nonce: nonce,
        origin_domain: to_string(domain || ""),
        key_id: normalize_optional_string(key_id),
        http_method: to_string(method || "") |> String.upcase(),
        request_path: canonical_path(request_path),
        timestamp: parse_int(timestamp, 0),
        seen_at: now,
        expires_at: expires_at,
        inserted_at: inserted_at
      }
    ]

    {count, _} = Repo.insert_all(FederationRequestReplay, attrs, on_conflict: :nothing)

    if count == 1, do: :ok, else: {:error, :replayed_request}
  end

  @doc "Builds a federated snapshot for a local server.\n"
  def build_server_snapshot(server_id, opts \\ []) do
    messages_per_channel = Keyword.get(opts, :messages_per_channel, 25)

    with %Server{} = server <- Repo.get(Server, server_id),
         false <- server.is_federated_mirror do
      channels =
        from(c in Conversation,
          where:
            c.server_id == ^server.id and c.type == "channel" and c.is_federated_mirror != true,
          order_by: [asc: c.channel_position, asc: c.inserted_at]
        )
        |> Repo.all()

      channel_payloads = Enum.map(channels, &channel_payload/1)

      channel_messages =
        Enum.flat_map(channels, fn channel ->
          from(m in ChatMessage,
            where: m.conversation_id == ^channel.id and is_nil(m.deleted_at),
            order_by: [desc: m.inserted_at],
            limit: ^messages_per_channel,
            preload: [:sender]
          )
          |> Repo.all()
          |> Enum.reverse()
          |> ChatMessage.decrypt_messages()
          |> Enum.map(fn message -> message_payload(message, channel) end)
        end)

      {:ok,
       %{
         "version" => 1,
         "origin_domain" => local_domain(),
         "server" => server_payload(server),
         "channels" => channel_payloads,
         "messages" => channel_messages
       }}
    else
      nil -> {:error, :not_found}
      true -> {:error, :federated_mirror}
    end
  end

  @doc "Imports a federated server snapshot from a trusted remote domain.\n"
  def import_server_snapshot(payload, remote_domain) when is_binary(remote_domain) do
    with :ok <- validate_snapshot_payload(payload, remote_domain) do
      Repo.transaction(fn ->
        with {:ok, mirror_server} <- upsert_mirror_server(payload["server"], remote_domain),
             {:ok, channel_map} <-
               upsert_mirror_channels(mirror_server, payload["channels"] || []),
             :ok <- upsert_mirror_messages(channel_map, payload["messages"] || [], remote_domain) do
          {:ok, mirror_server}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, {:ok, server}} -> {:ok, server}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Processes a single incoming real-time federation event.\n\nGuarantees:\n- idempotency by global event_id\n- in-order application per origin_domain + stream_id\n"
  def receive_event(payload, remote_domain) when is_binary(remote_domain) do
    with :ok <- validate_event_payload(payload, remote_domain) do
      payload = normalize_incoming_event_payload(payload)

      Repo.transaction(fn ->
        case claim_event_id(payload, remote_domain) do
          :duplicate ->
            :duplicate

          :new ->
            case check_sequence(payload, remote_domain) do
              :stale ->
                :stale

              :ok ->
                event_type = ArblargSDK.canonical_event_type(payload["event_type"])

                with :ok <-
                       apply_event(
                         event_type,
                         payload["payload"] || payload["data"] || %{},
                         remote_domain
                       ),
                     :ok <-
                       store_stream_position(
                         remote_domain,
                         payload["stream_id"],
                         payload["sequence"]
                       ) do
                  :applied
                else
                  {:error, reason} -> Repo.rollback(reason)
                end

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
      end)
      |> case do
        {:ok, result} when result in [:applied, :duplicate, :stale] -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Attempts automatic gap recovery by fetching a trusted remote snapshot.\n"
  def recover_sequence_gap(payload, remote_domain) when is_binary(remote_domain) do
    with %{} = peer <- incoming_peer(remote_domain),
         {:ok, remote_server_id} <- infer_remote_server_id(payload),
         {:ok, snapshot_payload} <- fetch_remote_snapshot(peer, remote_server_id),
         {:ok, _mirror_server} <- import_server_snapshot(snapshot_payload, remote_domain) do
      case receive_event(payload, remote_domain) do
        {:ok, :applied} -> {:ok, :recovered}
        {:ok, :duplicate} -> {:ok, :recovered}
        {:ok, :stale} -> {:ok, :recovered}
        {:error, reason} -> {:error, {:post_recovery_apply_failed, reason}}
      end
    else
      nil -> {:error, :unknown_peer}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :recovery_failed}
    end
  end

  @doc "Refreshes a mirrored server by fetching a fresh snapshot from its origin peer.\n"
  def refresh_mirror_server_snapshot(%Server{} = server) do
    with true <- server.is_federated_mirror == true,
         remote_domain when is_binary(remote_domain) <-
           normalize_optional_string(server.origin_domain),
         {:ok, remote_server_id} <-
           infer_remote_server_id_from_federation_id(server.federation_id),
         %{} = peer <- outgoing_peer(remote_domain) || incoming_peer(remote_domain),
         {:ok, snapshot_payload} <- fetch_remote_snapshot(peer, remote_server_id) do
      import_server_snapshot(snapshot_payload, remote_domain)
    else
      false ->
        {:error, :not_federated_mirror}

      nil ->
        {:error, :unknown_peer}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :cannot_infer_snapshot_server_id}
    end
  end

  def refresh_mirror_server_snapshot(_server), do: {:error, :not_federated_mirror}

  @doc "Pushes a local server snapshot to all configured outgoing peers.\n"
  def push_server_snapshot(server_id) do
    if enabled?() do
      with {:ok, snapshot} <- build_server_snapshot(server_id) do
        Enum.each(outgoing_peers(), fn peer -> push_snapshot_to_peer(peer, snapshot) end)
      end
    end

    :ok
  end

  @doc "Publishes a real-time server upsert event.\n"
  def publish_server_upsert(server_id) do
    if enabled?() do
      with {:ok, event} <- build_server_upsert_event(server_id) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  @doc "Publishes a real-time message.create event.\n"
  def publish_message_created(%ChatMessage{} = message) do
    if enabled?() do
      with {:ok, event} <- build_message_created_event(message) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  def publish_message_created(message_id) when is_integer(message_id) do
    case Repo.get(ChatMessage, message_id) do
      nil -> :ok
      message -> publish_message_created(message)
    end
  end

  @doc "Publishes a cross-instance dm.message.create event.\n"
  def publish_dm_message_created(%ChatMessage{} = message, remote_handle \\ nil) do
    if enabled?() do
      with {:ok, outbound_handle} <- resolve_outbound_dm_handle(message, remote_handle),
           {:ok, recipient} <- normalize_remote_dm_handle(outbound_handle),
           %{} <- outgoing_peer(recipient.domain),
           {:ok, event} <- build_dm_message_created_event(message, recipient.handle) do
        enqueue_outbox_event(event, [recipient.domain])
      end
    end

    :ok
  end

  @doc "Publishes a real-time message.update event.\n"
  def publish_message_updated(%ChatMessage{} = message) do
    if enabled?() do
      with {:ok, event} <- build_message_updated_event(message) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  def publish_message_updated(message_id) when is_integer(message_id) do
    case Repo.get(ChatMessage, message_id) do
      nil -> :ok
      message -> publish_message_updated(message)
    end
  end

  @doc "Publishes a real-time message.delete event.\n"
  def publish_message_deleted(%ChatMessage{} = message) do
    if enabled?() do
      with {:ok, event} <- build_message_deleted_event(message) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  def publish_message_deleted(message_id) when is_integer(message_id) do
    case Repo.get(ChatMessage, message_id) do
      nil -> :ok
      message -> publish_message_deleted(message)
    end
  end

  @doc "Publishes a real-time reaction.add event.\n"
  def publish_reaction_added(%ChatMessage{} = message, %ChatMessageReaction{} = reaction) do
    if enabled?() do
      with {:ok, event} <- build_reaction_added_event(message, reaction) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  @doc "Publishes a real-time reaction.remove event.\n"
  def publish_reaction_removed(%ChatMessage{} = message, user_id, emoji)
      when is_integer(user_id) do
    if enabled?() do
      with {:ok, event} <- build_reaction_removed_event(message, user_id, emoji) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  @doc "Publishes a real-time read.receipt event.\n"
  def publish_read_receipt(conversation_id, user_id, message_id, read_at \\ DateTime.utc_now())
      when is_integer(conversation_id) and is_integer(user_id) and is_integer(message_id) do
    if enabled?() do
      with {:ok, event} <- build_read_receipt_event(conversation_id, user_id, message_id, read_at) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  @doc "Submits a local message.create from mirror channel context.\n"
  def submit_mirror_message_created(%ChatMessage{} = message) do
    if enabled?() do
      with {:ok, event} <- build_message_created_event(message, allow_mirror: true) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  @doc "Submits a local message.update from mirror channel context.\n"
  def submit_mirror_message_updated(%ChatMessage{} = message) do
    if enabled?() do
      with {:ok, event} <- build_message_updated_event(message, allow_mirror: true) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  @doc "Submits a local message.delete from mirror channel context.\n"
  def submit_mirror_message_deleted(%ChatMessage{} = message) do
    if enabled?() do
      with {:ok, event} <- build_message_deleted_event(message, allow_mirror: true) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  @doc "Submits a local reaction.add from mirror channel context.\n"
  def submit_mirror_reaction_added(%ChatMessage{} = message, %ChatMessageReaction{} = reaction) do
    if enabled?() do
      with {:ok, event} <- build_reaction_added_event(message, reaction, allow_mirror: true) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  @doc "Submits a local reaction.remove from mirror channel context.\n"
  def submit_mirror_reaction_removed(%ChatMessage{} = message, user_id, emoji)
      when is_integer(user_id) do
    if enabled?() do
      with {:ok, event} <-
             build_reaction_removed_event(message, user_id, emoji, allow_mirror: true) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  @doc "Backward-compatible trigger used by existing call sites.\n"
  def maybe_push_for_conversation(conversation_id) do
    if enabled?() do
      Async.start(fn -> publish_latest_message_event(conversation_id) end)
    end

    :ok
  end

  @doc "Backward-compatible trigger used by existing call sites.\n"
  def maybe_push_for_server(server_id) do
    if enabled?() do
      Async.start(fn -> publish_server_upsert(server_id) end)
    end

    :ok
  end

  @doc "Processes one outbox row and attempts delivery to pending peers with bounded concurrency.\n"
  def process_outbox_event(outbox_event_id) when is_integer(outbox_event_id) do
    Repo.transaction(fn ->
      outbox =
        from(o in FederationOutboxEvent, where: o.id == ^outbox_event_id, lock: "FOR UPDATE")
        |> Repo.one()

      case outbox do
        nil ->
          :not_found

        %{status: "delivered"} ->
          :already_delivered

        %{status: "failed"} ->
          :already_failed

        %{next_retry_at: %DateTime{} = next_retry_at} ->
          if DateTime.compare(next_retry_at, DateTime.utc_now()) == :gt do
            :not_due
          else
            do_process_outbox(outbox)
          end

        _ ->
          do_process_outbox(outbox)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Enqueues due pending outbox events for processing.\n"
  def enqueue_due_outbox_events(limit \\ 500) do
    now = DateTime.utc_now()

    outbox_event_ids =
      from(o in FederationOutboxEvent,
        where:
          o.status == "pending" and o.attempt_count < o.max_attempts and o.next_retry_at <= ^now,
        order_by: [asc: o.next_retry_at, asc: o.id],
        limit: ^limit,
        select: o.id
      )
      |> Repo.all()

    _ = FederationOutboxWorker.enqueue_many(outbox_event_ids)
    length(outbox_event_ids)
  end

  @doc "Runs retention for federation event and outbox tables.\n"
  def run_retention do
    archive_old_events()
    prune_old_outbox_rows()
    prune_request_replays()
    :ok
  end

  defp validate_snapshot_payload(payload, remote_domain) when is_map(payload) do
    origin_domain = payload["origin_domain"]
    server = payload["server"] || %{}

    cond do
      payload["version"] != 1 -> {:error, :unsupported_version}
      origin_domain != remote_domain -> {:error, :origin_domain_mismatch}
      !is_map(server) -> {:error, :invalid_server_payload}
      !is_binary(server["id"]) or !is_binary(server["name"]) -> {:error, :invalid_server_payload}
      true -> :ok
    end
  end

  defp validate_snapshot_payload(_payload, _remote_domain) do
    {:error, :invalid_payload}
  end

  defp validate_event_payload(payload, remote_domain) when is_map(payload) do
    strict_signature_required? =
      Map.has_key?(payload, "protocol") or Map.has_key?(payload, "protocol_id") or
        Map.has_key?(payload, "protocol_version") or Map.has_key?(payload, "payload")

    payload = normalize_incoming_event_payload(payload)

    if payload["origin_domain"] != remote_domain do
      {:error, :origin_domain_mismatch}
    else
      case ArblargSDK.validate_event_envelope(payload) do
        :ok ->
          case maybe_require_event_signature(payload, strict_signature_required?) do
            :ok -> maybe_verify_envelope_signature(payload, remote_domain)
            error -> error
          end

        {:error, :unsupported_version} ->
          {:error, :unsupported_version}

        {:error, :unsupported_protocol} ->
          {:error, :unsupported_protocol}

        {:error, :unsupported_event_type} ->
          {:error, :unsupported_event_type}

        {:error, :invalid_event_id} ->
          {:error, :invalid_event_id}

        {:error, :invalid_stream_id} ->
          {:error, :invalid_stream_id}

        {:error, :invalid_sequence} ->
          {:error, :invalid_sequence}

        {:error, :invalid_idempotency_key} ->
          {:error, :invalid_idempotency_key}

        {:error, :invalid_event_payload} ->
          {:error, :invalid_event_payload}

        {:error, :invalid_signature} ->
          {:error, :invalid_event_signature}

        {:error, _} ->
          {:error, :invalid_payload}
      end
    end
  end

  defp validate_event_payload(_, _) do
    {:error, :invalid_payload}
  end

  defp maybe_verify_envelope_signature(payload, remote_domain) do
    case payload["signature"] do
      %{} ->
        case incoming_peer(remote_domain) do
          %{} = peer ->
            key_lookup = fn key_id -> incoming_verification_materials_for_key_id(peer, key_id) end

            if ArblargSDK.verify_event_envelope_signature(payload, key_lookup) do
              :ok
            else
              {:error, :invalid_event_signature}
            end

          _ ->
            {:error, :unknown_peer}
        end

      _ ->
        :ok
    end
  end

  defp maybe_require_event_signature(payload, true) when is_map(payload) do
    if is_map(payload["signature"]), do: :ok, else: {:error, :invalid_event_signature}
  end

  defp maybe_require_event_signature(_payload, _strict), do: :ok

  defp claim_event_id(payload, remote_domain) do
    payload = normalize_incoming_event_payload(payload)
    inserted_now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    received_now = DateTime.utc_now() |> DateTime.truncate(:second)

    protocol_version = payload["protocol_version"] || ArblargSDK.protocol_version()
    idempotency_key = payload["idempotency_key"] || payload["event_id"]

    attrs = [
      %{
        protocol_version: protocol_version,
        event_id: payload["event_id"],
        idempotency_key: idempotency_key,
        origin_domain: remote_domain,
        event_type: ArblargSDK.canonical_event_type(payload["event_type"]),
        stream_id: payload["stream_id"],
        sequence: parse_int(payload["sequence"], 0),
        payload: payload,
        received_at: received_now,
        inserted_at: inserted_now
      }
    ]

    {count, _} = Repo.insert_all(FederationEvent, attrs, on_conflict: :nothing)

    if count == 1 do
      :new
    else
      :duplicate
    end
  end

  defp check_sequence(payload, remote_domain) do
    stream_id = payload["stream_id"]
    incoming_sequence = parse_int(payload["sequence"], 0)

    position =
      from(p in FederationStreamPosition,
        where: p.origin_domain == ^remote_domain and p.stream_id == ^stream_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    last_sequence =
      if position do
        position.last_sequence
      else
        0
      end

    cond do
      incoming_sequence <= last_sequence -> :stale
      incoming_sequence > last_sequence + 1 -> {:error, :sequence_gap}
      true -> :ok
    end
  end

  defp store_stream_position(remote_domain, stream_id, sequence) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    attrs = [
      %{
        origin_domain: remote_domain,
        stream_id: stream_id,
        last_sequence: parse_int(sequence, 0),
        inserted_at: now,
        updated_at: now
      }
    ]

    {_count, _} =
      Repo.insert_all(FederationStreamPosition, attrs,
        on_conflict: [set: [last_sequence: parse_int(sequence, 0), updated_at: now]],
        conflict_target: [:origin_domain, :stream_id]
      )

    :ok
  end

  defp apply_event(@bootstrap_server_upsert_event_type, data, remote_domain) do
    apply_event("server.upsert", data, remote_domain)
  end

  defp apply_event(@dm_message_create_event_type, data, remote_domain) do
    apply_event("dm.message.create", data, remote_domain)
  end

  defp apply_event("dm.message.create", data, remote_domain) do
    with %{} = dm_payload <- data["dm"],
         %{} = message_payload <- data["message"],
         {:ok, recipient_user} <- resolve_local_dm_recipient(dm_payload["recipient"]),
         {:ok, remote_sender} <- resolve_remote_dm_sender(dm_payload["sender"], remote_domain),
         {:ok, conversation} <- ensure_remote_dm_conversation(recipient_user, remote_sender),
         {:ok, message_or_duplicate} <-
           upsert_remote_dm_message(conversation, message_payload, remote_domain, remote_sender),
         :ok <-
           maybe_broadcast_remote_dm_message_created(
             conversation,
             message_or_duplicate,
             recipient_user,
             remote_sender
           ) do
      :ok
    else
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event("server.upsert", data, remote_domain) do
    with %{} = server_payload <- data["server"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, _channel_map} <- upsert_mirror_channels(mirror_server, data["channels"] || []) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event("message.create", data, remote_domain) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = message_payload <- data["message"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         {:ok, mirror_message_or_duplicate} <-
           upsert_mirror_message(mirror_channel, message_payload, remote_domain),
         :ok <- maybe_broadcast_mirror_message_created(mirror_message_or_duplicate) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event("message.update", data, remote_domain) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = message_payload <- data["message"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         {:ok, mirror_message} <-
           upsert_or_update_mirror_message(mirror_channel, message_payload, remote_domain),
         :ok <- maybe_broadcast_mirror_message_updated(mirror_message) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event("message.delete", data, remote_domain) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         message_id when is_binary(message_id) <- data["message_id"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         {:ok, deleted_message} <-
           soft_delete_mirror_message(mirror_channel, message_id, data["deleted_at"]),
         :ok <- maybe_broadcast_mirror_message_deleted(deleted_message.id) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event("reaction.add", data, remote_domain) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         message_id when is_binary(message_id) <- data["message_id"],
         reaction when is_map(reaction) <- data["reaction"],
         emoji when is_binary(emoji) <- reaction["emoji"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         {:ok, message} <- get_mirror_message(mirror_channel, message_id),
         {:ok, remote_actor_id} <-
           resolve_or_create_remote_actor_id(reaction["actor"], remote_domain),
         {:ok, reaction_or_duplicate} <- add_mirror_reaction(message.id, remote_actor_id, emoji),
         :ok <- maybe_broadcast_mirror_reaction_added(message.id, reaction_or_duplicate) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event("reaction.remove", data, remote_domain) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         message_id when is_binary(message_id) <- data["message_id"],
         reaction when is_map(reaction) <- data["reaction"],
         emoji when is_binary(emoji) <- reaction["emoji"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         {:ok, message} <- get_mirror_message(mirror_channel, message_id),
         {:ok, remote_actor_id} <-
           resolve_or_create_remote_actor_id(reaction["actor"], remote_domain),
         {:ok, removed_count} <- remove_mirror_reaction(message.id, remote_actor_id, emoji),
         :ok <-
           maybe_broadcast_mirror_reaction_removed(
             message.id,
             remote_actor_id,
             emoji,
             removed_count
           ) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event("read.receipt", data, remote_domain) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         message_id when is_binary(message_id) <- data["message_id"],
         %{} = actor_payload <- data["actor"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         {:ok, message} <- get_mirror_message(mirror_channel, message_id),
         {:ok, remote_actor_id} <- resolve_or_create_remote_actor_id(actor_payload, remote_domain),
         read_at <- parse_datetime(data["read_at"]) || DateTime.utc_now(),
         {:ok, _receipt} <-
           upsert_remote_read_receipt(message.id, remote_actor_id, remote_domain, read_at),
         :ok <- maybe_broadcast_remote_read_receipt(message.id, remote_actor_id, read_at) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event(event_type, data, remote_domain)
       when event_type in [@role_upsert_event_type, "role.upsert"] do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = role_payload <- data["role"],
         role_id when is_binary(role_id) <- role_payload["id"],
         role_name when is_binary(role_name) <- role_payload["name"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         event_key <- "role:#{role_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           upsert_extension_projection(
             @role_upsert_event_type,
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             parse_datetime(role_payload["updated_at"]) || DateTime.utc_now()
           ),
         :ok <-
           upsert_extension_system_message(
             mirror_channel,
             @role_upsert_event_type,
             event_key,
             "Role updated: #{role_name}",
             %{
               "event_type" => @role_upsert_event_type,
               "role" => role_payload
             },
             remote_domain
           ) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event(event_type, data, remote_domain)
       when event_type in [@role_assignment_upsert_event_type, "role.assignment.upsert"] do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = assignment_payload <- data["assignment"],
         role_id when is_binary(role_id) <- assignment_payload["role_id"],
         %{} = target <- assignment_payload["target"],
         target_type when is_binary(target_type) <- target["type"],
         target_id when is_binary(target_id) <- target["id"],
         state when is_binary(state) <- assignment_payload["state"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         event_key <-
           "role_assignment:#{role_id}:#{target_type}:#{target_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           upsert_extension_projection(
             @role_assignment_upsert_event_type,
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             DateTime.utc_now()
           ),
         :ok <-
           upsert_extension_system_message(
             mirror_channel,
             @role_assignment_upsert_event_type,
             event_key,
             "Role #{state}: #{role_id} -> #{target_type}:#{target_id}",
             %{
               "event_type" => @role_assignment_upsert_event_type,
               "assignment" => assignment_payload
             },
             remote_domain
           ) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event(event_type, data, remote_domain)
       when event_type in [@permission_overwrite_upsert_event_type, "permission.overwrite.upsert"] do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = overwrite_payload <- data["overwrite"],
         overwrite_id when is_binary(overwrite_id) <- overwrite_payload["id"],
         %{} = target <- overwrite_payload["target"],
         target_type when is_binary(target_type) <- target["type"],
         target_id when is_binary(target_id) <- target["id"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         event_key <- "overwrite:#{overwrite_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           upsert_extension_projection(
             @permission_overwrite_upsert_event_type,
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             DateTime.utc_now()
           ),
         :ok <-
           upsert_extension_system_message(
             mirror_channel,
             @permission_overwrite_upsert_event_type,
             event_key,
             "Permissions updated for #{target_type}:#{target_id}",
             %{
               "event_type" => @permission_overwrite_upsert_event_type,
               "overwrite" => overwrite_payload
             },
             remote_domain
           ) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event(event_type, data, remote_domain)
       when event_type in [@thread_upsert_event_type, "thread.upsert"] do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = thread_payload <- data["thread"],
         thread_id when is_binary(thread_id) <- thread_payload["id"],
         thread_name when is_binary(thread_name) <- thread_payload["name"],
         thread_state when is_binary(thread_state) <- thread_payload["state"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         event_key <- "thread:#{thread_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           upsert_extension_projection(
             @thread_upsert_event_type,
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             DateTime.utc_now(),
             thread_state
           ),
         :ok <-
           upsert_extension_system_message(
             mirror_channel,
             @thread_upsert_event_type,
             event_key,
             "Thread #{thread_state}: #{thread_name}",
             %{
               "event_type" => @thread_upsert_event_type,
               "thread" => thread_payload
             },
             remote_domain
           ) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event(event_type, data, remote_domain)
       when event_type in [@thread_archive_event_type, "thread.archive"] do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         thread_id when is_binary(thread_id) <- data["thread_id"],
         archived_at <- parse_datetime(data["archived_at"]) || DateTime.utc_now(),
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         event_key <- "thread:#{thread_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           upsert_extension_projection(
             @thread_archive_event_type,
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             archived_at,
             "archived"
           ),
         :ok <-
           upsert_extension_system_message(
             mirror_channel,
             @thread_archive_event_type,
             event_key,
             "Thread archived: #{thread_id}",
             %{
               "event_type" => @thread_archive_event_type,
               "thread_id" => thread_id,
               "archived_at" => DateTime.to_iso8601(archived_at),
               "reason" => data["reason"]
             },
             remote_domain
           ) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event(event_type, data, remote_domain)
       when event_type in [@presence_update_event_type, "presence.update"] do
    with %{} = server_payload <- data["server"],
         %{} = presence_payload <- data["presence"],
         %{} = actor_payload <- presence_payload["actor"],
         status when is_binary(status) <- presence_payload["status"],
         updated_at <- parse_datetime(presence_payload["updated_at"]) || DateTime.utc_now(),
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, remote_actor_id} <- resolve_or_create_remote_actor_id(actor_payload, remote_domain),
         {:ok, _presence_state} <-
           upsert_presence_state(
             mirror_server.id,
             remote_actor_id,
             status,
             normalize_presence_activities(presence_payload["activities"]),
             updated_at,
             remote_domain
           ),
         {:ok, _event_projection} <-
           upsert_extension_projection(
             @presence_update_event_type,
             "presence:#{remote_actor_id}:server:#{mirror_server.id}",
             data,
             remote_domain,
             mirror_server.id,
             nil,
             updated_at,
             status
           ),
         :ok <-
           maybe_broadcast_presence_update(
             mirror_server.id,
             remote_actor_id,
             status,
             normalize_presence_activities(presence_payload["activities"]),
             updated_at
           ) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event(event_type, data, remote_domain)
       when event_type in [@moderation_action_recorded_event_type, "moderation.action.recorded"] do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = action_payload <- data["action"],
         action_id when is_binary(action_id) <- action_payload["id"],
         action_kind when is_binary(action_kind) <- action_payload["kind"],
         target when is_map(target) <- action_payload["target"],
         target_type when is_binary(target_type) <- target["type"],
         target_id when is_binary(target_id) <- target["id"],
         occurred_at <- parse_datetime(action_payload["occurred_at"]) || DateTime.utc_now(),
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         event_key <- "moderation:#{action_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           upsert_extension_projection(
             @moderation_action_recorded_event_type,
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             occurred_at,
             action_kind
           ),
         :ok <-
           upsert_extension_system_message(
             mirror_channel,
             @moderation_action_recorded_event_type,
             event_key,
             "Moderation action (#{action_kind}) on #{target_type}:#{target_id}",
             %{
               "event_type" => @moderation_action_recorded_event_type,
               "action" => action_payload
             },
             remote_domain
           ) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event(event_type, data, _remote_domain) do
    if event_type in @discord_extension_event_types do
      case ArblargSDK.validate_event_payload(event_type, data) do
        :ok -> :ok
        _ -> {:error, :invalid_event_payload}
      end
    else
      {:error, :unsupported_event_type}
    end
  end

  defp build_server_upsert_event(server_id) do
    with %Server{} = server <- Repo.get(Server, server_id),
         false <- server.is_federated_mirror do
      channels =
        from(c in Conversation,
          where:
            c.server_id == ^server.id and c.type == "channel" and c.is_federated_mirror != true,
          order_by: [asc: c.channel_position, asc: c.inserted_at]
        )
        |> Repo.all()

      stream_id = server_stream_id(server.id)
      sequence = next_outbound_sequence(stream_id)

      {:ok,
       event_envelope(ArblargSDK.bootstrap_server_upsert_event_type(), stream_id, sequence, %{
         "server" => server_payload(server),
         "channels" => Enum.map(channels, &channel_payload/1)
       })}
    else
      nil -> {:error, :not_found}
      true -> {:error, :federated_mirror}
    end
  end

  defp build_message_created_event(%ChatMessage{} = message, opts \\ []) do
    allow_mirror? = Keyword.get(opts, :allow_mirror, false)
    message = Repo.preload(message, [:sender, conversation: [:server]])
    conversation = message.conversation

    server =
      if conversation do
        conversation.server
      else
        nil
      end

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror and not allow_mirror? ->
        {:error, :federated_mirror}

      true ->
        stream_id = channel_stream_id(conversation.id)
        sequence = next_outbound_sequence(stream_id)

        {:ok,
         event_envelope("message.create", stream_id, sequence, %{
           "server" => server_payload(server),
           "channel" => channel_payload(conversation),
           "message" => message_payload(message, conversation)
         })}
    end
  end

  defp build_dm_message_created_event(%ChatMessage{} = message, remote_handle)
       when is_binary(remote_handle) do
    message = Repo.preload(message, [:sender, :conversation])
    conversation = message.conversation

    with {:ok, recipient} <- normalize_remote_dm_handle(remote_handle),
         %Conversation{} <- conversation,
         true <- conversation.type == "dm",
         true <- is_integer(message.sender_id),
         %User{} = sender <- message.sender,
         conversation_handle when is_binary(conversation_handle) <-
           remote_dm_handle_from_source(conversation.federated_source),
         true <- conversation_handle == recipient.handle do
      stream_id = dm_stream_id(conversation.id)
      sequence = next_outbound_sequence(stream_id)
      dm_id = dm_federation_id(conversation.id)
      sender_data = sender_payload(sender)

      {:ok,
       event_envelope(@dm_message_create_event_type, stream_id, sequence, %{
         "dm" => %{
           "id" => dm_id,
           "sender" => sender_data,
           "recipient" => dm_actor_payload(recipient)
         },
         "message" => %{
           "id" => message.federated_source || message_federation_id(message.id),
           "dm_id" => dm_id,
           "content" => message.content || "",
           "message_type" => message.message_type || "text",
           "media_urls" => message.media_urls || [],
           "media_metadata" => message.media_metadata || %{},
           "created_at" => format_created_at(message.inserted_at),
           "edited_at" => format_created_at(message.edited_at),
           "sender" => sender_data
         }
       })}
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_event_payload}
      _ -> {:error, :unsupported_conversation_type}
    end
  end

  defp build_message_updated_event(%ChatMessage{} = message, opts \\ []) do
    allow_mirror? = Keyword.get(opts, :allow_mirror, false)
    message = Repo.preload(message, [:sender, conversation: [:server]])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror and not allow_mirror? ->
        {:error, :federated_mirror}

      true ->
        stream_id = channel_stream_id(conversation.id)
        sequence = next_outbound_sequence(stream_id)

        {:ok,
         event_envelope("message.update", stream_id, sequence, %{
           "server" => server_payload(server),
           "channel" => channel_payload(conversation),
           "message" => message_payload(message, conversation)
         })}
    end
  end

  defp build_message_deleted_event(%ChatMessage{} = message, opts \\ []) do
    allow_mirror? = Keyword.get(opts, :allow_mirror, false)
    message = Repo.preload(message, conversation: [:server])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror and not allow_mirror? ->
        {:error, :federated_mirror}

      true ->
        stream_id = channel_stream_id(conversation.id)
        sequence = next_outbound_sequence(stream_id)

        {:ok,
         event_envelope("message.delete", stream_id, sequence, %{
           "server" => server_payload(server),
           "channel" => channel_payload(conversation),
           "message_id" => message.federated_source || message_federation_id(message.id),
           "deleted_at" => format_created_at(message.deleted_at || DateTime.utc_now())
         })}
    end
  end

  defp build_reaction_added_event(
         %ChatMessage{} = message,
         %ChatMessageReaction{} = reaction,
         opts \\ []
       ) do
    allow_mirror? = Keyword.get(opts, :allow_mirror, false)
    message = Repo.preload(message, conversation: [:server])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      is_nil(reaction.user_id) ->
        {:error, :unsupported_reaction_actor}

      server.is_federated_mirror and not allow_mirror? ->
        {:error, :federated_mirror}

      true ->
        user = Repo.get(Elektrine.Accounts.User, reaction.user_id)

        if is_nil(user) do
          {:error, :not_found}
        else
          stream_id = channel_stream_id(conversation.id)
          sequence = next_outbound_sequence(stream_id)

          {:ok,
           event_envelope("reaction.add", stream_id, sequence, %{
             "server" => server_payload(server),
             "channel" => channel_payload(conversation),
             "message_id" => message.federated_source || message_federation_id(message.id),
             "reaction" => %{
               "emoji" => reaction.emoji,
               "actor" => sender_payload(user)
             }
           })}
        end
    end
  end

  defp build_reaction_removed_event(%ChatMessage{} = message, user_id, emoji, opts \\ [])
       when is_integer(user_id) do
    allow_mirror? = Keyword.get(opts, :allow_mirror, false)
    message = Repo.preload(message, conversation: [:server])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror and not allow_mirror? ->
        {:error, :federated_mirror}

      true ->
        user = Repo.get(Elektrine.Accounts.User, user_id)

        if is_nil(user) do
          {:error, :not_found}
        else
          stream_id = channel_stream_id(conversation.id)
          sequence = next_outbound_sequence(stream_id)

          {:ok,
           event_envelope("reaction.remove", stream_id, sequence, %{
             "server" => server_payload(server),
             "channel" => channel_payload(conversation),
             "message_id" => message.federated_source || message_federation_id(message.id),
             "reaction" => %{
               "emoji" => emoji,
               "actor" => sender_payload(user)
             }
           })}
        end
    end
  end

  defp build_read_receipt_event(conversation_id, user_id, message_id, read_at) do
    conversation = Repo.get(Conversation, conversation_id) |> Repo.preload(:server)
    message = Repo.get(ChatMessage, message_id)
    user = Repo.get(User, user_id)

    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) or is_nil(message) or is_nil(user) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror ->
        {:error, :federated_mirror}

      message.conversation_id != conversation.id ->
        {:error, :invalid_event_payload}

      true ->
        stream_id = channel_stream_id(conversation.id)
        sequence = next_outbound_sequence(stream_id)

        {:ok,
         event_envelope("read.receipt", stream_id, sequence, %{
           "server" => server_payload(server),
           "channel" => channel_payload(conversation),
           "message_id" => message.federated_source || message_federation_id(message.id),
           "actor" => sender_payload(user),
           "read_at" => format_created_at(read_at || DateTime.utc_now())
         })}
    end
  end

  defp event_envelope(event_type, stream_id, sequence, data) do
    unsigned = %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_version" => ArblargSDK.protocol_version(),
      "version" => 1,
      "event_id" => Ecto.UUID.generate(),
      "event_type" => event_type,
      "origin_domain" => local_domain(),
      "stream_id" => stream_id,
      "sequence" => sequence,
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "idempotency_key" => Ecto.UUID.generate(),
      "payload" => data,
      "data" => data
    }

    {key_id, signing_material} = local_event_signing_material()
    ArblargSDK.sign_event_envelope(unsigned, key_id, signing_material)
  end

  defp enqueue_outbox_event(event, target_domains \\ :all)

  defp enqueue_outbox_event(event, :all) do
    peer_domains = outgoing_peers() |> Enum.map(&String.downcase(&1.domain)) |> Enum.uniq()
    do_enqueue_outbox_event(event, peer_domains)
  end

  defp enqueue_outbox_event(event, target_domains) when is_list(target_domains) do
    outgoing_domain_set =
      outgoing_peers()
      |> Enum.map(&String.downcase(&1.domain))
      |> MapSet.new()

    filtered_domains =
      target_domains
      |> Enum.map(&normalize_optional_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(&MapSet.member?(outgoing_domain_set, &1))
      |> Enum.uniq()

    do_enqueue_outbox_event(event, filtered_domains)
  end

  defp enqueue_outbox_event(event, _target_domains), do: enqueue_outbox_event(event, :all)

  defp do_enqueue_outbox_event(_event, []), do: :ok

  defp do_enqueue_outbox_event(event, peer_domains) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      event_id: event["event_id"],
      event_type: event["event_type"],
      stream_id: event["stream_id"],
      sequence: parse_int(event["sequence"], 0),
      payload: event,
      target_domains: peer_domains,
      delivered_domains: [],
      attempt_count: 0,
      max_attempts: outbox_max_attempts(),
      status: "pending",
      next_retry_at: now,
      partition_month: outbox_partition_month(now)
    }

    case %FederationOutboxEvent{} |> FederationOutboxEvent.changeset(attrs) |> Repo.insert() do
      {:ok, outbox_event} ->
        _ = FederationOutboxWorker.enqueue(outbox_event.id)
        :ok

      {:error, %Ecto.Changeset{errors: [event_id: _]}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue federation outbox event: #{inspect(reason)}")
        :ok
    end
  end

  defp do_process_outbox(outbox) do
    pending = pending_domains(outbox)

    if pending == [] do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      outbox
      |> FederationOutboxEvent.changeset(%{
        status: "delivered",
        dispatched_at: now,
        delivered_domains: outbox.target_domains
      })
      |> Repo.update()

      :delivered
    else
      {successful_domains, failed_domains} = deliver_outbox_domains(outbox.payload, pending)
      delivered_domains = Enum.uniq(outbox.delivered_domains ++ successful_domains)

      if failed_domains == [] do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        outbox
        |> FederationOutboxEvent.changeset(%{
          status: "delivered",
          delivered_domains: delivered_domains,
          dispatched_at: now,
          attempt_count: outbox.attempt_count + 1,
          next_retry_at: now,
          last_error: nil
        })
        |> Repo.update()

        :delivered
      else
        attempt_count = outbox.attempt_count + 1
        exhausted = attempt_count >= outbox.max_attempts
        backoff_seconds = outbox_backoff_seconds(attempt_count)
        next_retry_at = DateTime.add(DateTime.utc_now(), backoff_seconds, :second)

        status =
          if exhausted do
            "failed"
          else
            "pending"
          end

        error_reason =
          failed_domains
          |> Enum.map_join("; ", fn {domain, reason} -> "#{domain}: #{inspect(reason)}" end)

        outbox
        |> FederationOutboxEvent.changeset(%{
          status: status,
          delivered_domains: delivered_domains,
          attempt_count: attempt_count,
          next_retry_at: next_retry_at,
          last_error: error_reason
        })
        |> Repo.update()

        if exhausted do
          :failed
        else
          :pending_retry
        end
      end
    end
  end

  defp pending_domains(outbox) do
    delivered = MapSet.new(outbox.delivered_domains || [])
    outbox.target_domains |> Enum.reject(&MapSet.member?(delivered, &1))
  end

  defp deliver_outbox_domains(event_payload, domains) do
    peer_map =
      outgoing_peers()
      |> Enum.map(fn peer -> {String.downcase(peer.domain), peer} end)
      |> Map.new()

    domains
    |> Task.async_stream(
      fn domain ->
        normalized = String.downcase(domain)

        case Map.get(peer_map, normalized) do
          nil ->
            {:error, domain, :unknown_peer}

          peer ->
            case push_event_to_peer(peer, event_payload) do
              :ok -> {:ok, domain}
              {:error, reason} -> {:error, domain, reason}
            end
        end
      end,
      max_concurrency: delivery_concurrency(),
      timeout: delivery_timeout_ms(),
      ordered: false
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {:ok, domain}}, {successes, failures} ->
        {[domain | successes], failures}

      {:ok, {:error, domain, reason}}, {successes, failures} ->
        {successes, [{domain, reason} | failures]}

      {:exit, reason}, {successes, failures} ->
        {successes, [{"unknown", {:task_exit, reason}} | failures]}
    end)
  end

  defp push_event_to_peer(peer, event) do
    path = "/federation/messaging/events"
    url = outbound_events_url(peer)
    body = Jason.encode!(event)
    headers = signed_headers(peer, "POST", path, "", body)
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Elektrine.Finch,
           receive_timeout: delivery_timeout_ms(),
           pool_timeout: 5000
         ) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, truncate(response_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_snapshot_to_peer(peer, snapshot) do
    path = "/federation/messaging/sync"
    url = outbound_sync_url(peer)
    body = Jason.encode!(snapshot)
    headers = signed_headers(peer, "POST", path, "", body)
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Elektrine.Finch,
           receive_timeout: delivery_timeout_ms(),
           pool_timeout: 5000
         ) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        Logger.warning(
          "Messaging federation sync failed for #{peer.domain}: HTTP #{status} #{truncate(response_body)}"
        )

      {:error, reason} ->
        Logger.warning(
          "Messaging federation sync transport error for #{peer.domain}: #{inspect(reason)}"
        )
    end
  end

  defp fetch_remote_snapshot(peer, remote_server_id) when is_integer(remote_server_id) do
    path = "/federation/messaging/servers/#{remote_server_id}/snapshot"
    url = outbound_snapshot_url(peer, remote_server_id)
    headers = signed_headers(peer, "GET", path, "", "")
    request = Finch.build(:get, url, headers)

    case Finch.request(request, Elektrine.Finch,
           receive_timeout: delivery_timeout_ms(),
           pool_timeout: 5000
         ) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, payload} -> {:ok, payload}
          _ -> {:error, :invalid_snapshot_response}
        end

      {:ok, %Finch.Response{status: status}} when status in [404, 422] ->
        {:error, :snapshot_unavailable}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, truncate(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_mirror_server(server_payload, remote_domain) do
    attrs = %{
      name: server_payload["name"],
      description: server_payload["description"],
      icon_url: server_payload["icon_url"],
      is_public: server_payload["is_public"] == true,
      member_count: parse_int(server_payload["member_count"], 0),
      federation_id: server_payload["id"],
      origin_domain: remote_domain,
      is_federated_mirror: true,
      last_federated_at: DateTime.utc_now()
    }

    case Repo.get_by(Server, federation_id: server_payload["id"]) do
      nil ->
        %Server{} |> Server.changeset(attrs) |> Repo.insert()

      %Server{origin_domain: existing_origin} = server ->
        if is_binary(existing_origin) and existing_origin != remote_domain do
          {:error, :federation_origin_conflict}
        else
          server |> Server.changeset(attrs) |> Repo.update()
        end
    end
  end

  defp upsert_mirror_channels(server, channels) when is_list(channels) do
    channels
    |> Enum.reduce_while({:ok, %{}}, fn payload, {:ok, acc} ->
      case upsert_single_mirror_channel(server, payload) do
        {:ok, channel} ->
          {:cont, {:ok, Map.put(acc, payload["id"], channel)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_single_mirror_channel(server, %{"id" => channel_id} = channel_payload) do
    attrs = %{
      name: channel_payload["name"] || "channel",
      description: channel_payload["description"],
      channel_topic: channel_payload["topic"],
      channel_position: parse_int(channel_payload["position"], 0),
      creator_id: nil,
      server_id: server.id,
      is_public: true,
      is_federated_mirror: true,
      federated_source: channel_id
    }

    case Repo.get_by(Conversation, type: "channel", federated_source: channel_id) do
      nil ->
        %Conversation{} |> Conversation.channel_changeset(attrs) |> Repo.insert()

      %Conversation{} = channel ->
        with :ok <- ensure_channel_origin_matches(channel, server.origin_domain) do
          channel |> Conversation.changeset(attrs) |> Repo.update()
        end
    end
  end

  defp upsert_single_mirror_channel(_server, _) do
    {:error, :invalid_channel}
  end

  defp ensure_channel_origin_matches(%Conversation{server_id: server_id}, remote_domain)
       when is_integer(server_id) and is_binary(remote_domain) do
    case Repo.get(Server, server_id) do
      %Server{origin_domain: ^remote_domain} -> :ok
      %Server{origin_domain: nil} -> :ok
      %Server{} -> {:error, :federation_origin_conflict}
      nil -> {:error, :federation_origin_conflict}
    end
  end

  defp ensure_channel_origin_matches(_, _), do: {:error, :federation_origin_conflict}

  defp upsert_mirror_messages(channel_map, messages, remote_domain) when is_list(messages) do
    messages
    |> Enum.reduce_while(:ok, fn payload, :ok ->
      channel = Map.get(channel_map, payload["channel_id"])

      if channel do
        case upsert_mirror_message(channel, payload, remote_domain) do
          {:ok, _result} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp upsert_mirror_message(channel, payload, remote_domain) do
    federation_id = payload["id"]

    cond do
      is_nil(channel) ->
        {:error, :invalid_channel}

      !is_binary(federation_id) ->
        {:error, :invalid_message_payload}

      Repo.get_by(ChatMessage, conversation_id: channel.id, federated_source: federation_id) ->
        {:ok, :duplicate}

      true ->
        media_metadata =
          (payload["media_metadata"] || %{}) |> Map.put("remote_sender", payload["sender"] || %{})

        attrs = %{
          conversation_id: channel.id,
          sender_id: nil,
          content: payload["content"],
          message_type: normalize_message_type(payload["message_type"]),
          media_urls: payload["media_urls"] || [],
          media_metadata: media_metadata,
          federated_source: federation_id,
          origin_domain: remote_domain,
          is_federated_mirror: true
        }

        %ChatMessage{} |> ChatMessage.changeset(attrs) |> Repo.insert()
    end
  end

  defp upsert_or_update_mirror_message(channel, payload, remote_domain) do
    federation_id = payload["id"]

    with true <- is_binary(federation_id),
         %ChatMessage{} = existing <-
           Repo.get_by(ChatMessage, conversation_id: channel.id, federated_source: federation_id) do
      media_metadata =
        (payload["media_metadata"] || %{}) |> Map.put("remote_sender", payload["sender"] || %{})

      attrs = %{
        content: payload["content"],
        message_type: normalize_message_type(payload["message_type"]),
        media_urls: payload["media_urls"] || [],
        media_metadata: media_metadata,
        edited_at: parse_datetime(payload["edited_at"]) || DateTime.utc_now()
      }

      existing
      |> ChatMessage.changeset(attrs)
      |> Repo.update()
    else
      _ -> upsert_mirror_message(channel, payload, remote_domain)
    end
  end

  defp soft_delete_mirror_message(channel, federation_message_id, deleted_at) do
    case Repo.get_by(ChatMessage,
           conversation_id: channel.id,
           federated_source: federation_message_id
         ) do
      nil ->
        {:error, :not_found}

      %ChatMessage{} = message ->
        attrs = %{deleted_at: parse_datetime(deleted_at) || DateTime.utc_now()}

        case message |> ChatMessage.changeset(attrs) |> Repo.update() do
          {:ok, updated} -> {:ok, updated}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp get_mirror_message(channel, federation_message_id) do
    case Repo.get_by(ChatMessage,
           conversation_id: channel.id,
           federated_source: federation_message_id
         ) do
      nil -> {:error, :not_found}
      %ChatMessage{} = message -> {:ok, message}
    end
  end

  defp resolve_remote_actor_id(%{"uri" => uri}) when is_binary(uri) do
    case Repo.get_by(ActivityPubActor, uri: uri) do
      %ActivityPubActor{id: actor_id} ->
        {:ok, actor_id}

      nil ->
        {:error, :actor_not_found}
    end
  end

  defp resolve_remote_actor_id(_), do: {:error, :invalid_actor}

  defp resolve_or_create_remote_actor_id(actor_payload, remote_domain)
       when is_map(actor_payload) and is_binary(remote_domain) do
    case resolve_remote_actor_id(actor_payload) do
      {:ok, actor_id} ->
        {:ok, actor_id}

      _ ->
        upsert_remote_actor(actor_payload, remote_domain)
    end
  end

  defp resolve_or_create_remote_actor_id(_actor_payload, _remote_domain),
    do: {:error, :invalid_actor}

  defp upsert_remote_actor(actor_payload, remote_domain)
       when is_map(actor_payload) and is_binary(remote_domain) do
    raw_uri =
      normalize_optional_string(
        actor_payload["uri"] || actor_payload["id"] || actor_payload["actor"] ||
          actor_payload["url"]
      )

    normalized_remote_domain = String.downcase(remote_domain)

    {username, domain} =
      case normalize_dm_actor_payload(actor_payload, normalized_remote_domain) do
        {:ok, actor} ->
          {actor.username, actor.domain}

        _ ->
          fallback_username =
            actor_payload["username"] ||
              actor_payload["handle"] ||
              actor_payload["name"] ||
              "remote-#{System.unique_integer([:positive, :monotonic])}"

          cleaned_username =
            fallback_username
            |> to_string()
            |> String.downcase()
            |> String.replace(~r/[^a-z0-9_]/, "_")
            |> String.trim("_")
            |> case do
              "" -> "remote"
              value -> String.slice(value, 0, 30)
            end

          {cleaned_username, normalized_remote_domain}
      end

    uri =
      raw_uri ||
        "https://#{domain}/users/#{username}"

    display_name =
      normalize_optional_string(
        actor_payload["display_name"] || actor_payload["name"] || actor_payload["username"]
      )

    avatar_url =
      normalize_optional_string(
        actor_payload["avatar_url"] || actor_payload["avatar"] || actor_payload["icon_url"]
      )

    inbox_url =
      normalize_optional_string(actor_payload["inbox_url"] || actor_payload["inbox"]) ||
        "https://#{domain}/inbox"

    public_key = remote_actor_public_key(actor_payload)

    attrs = %{
      uri: uri,
      username: username,
      domain: domain,
      display_name: display_name,
      avatar_url: avatar_url,
      inbox_url: inbox_url,
      public_key: public_key,
      actor_type: "Person"
    }

    case Repo.get_by(ActivityPubActor, uri: uri) do
      %ActivityPubActor{id: actor_id} = actor ->
        _ = actor |> ActivityPubActor.changeset(attrs) |> Repo.update()
        {:ok, actor_id}

      nil ->
        case Repo.get_by(ActivityPubActor, username: username, domain: domain) do
          %ActivityPubActor{id: actor_id} = actor ->
            _ = actor |> ActivityPubActor.changeset(attrs) |> Repo.update()
            {:ok, actor_id}

          nil ->
            case %ActivityPubActor{} |> ActivityPubActor.changeset(attrs) |> Repo.insert() do
              {:ok, actor} -> {:ok, actor.id}
              {:error, _} -> {:error, :actor_not_found}
            end
        end
    end
  end

  defp upsert_remote_actor(_actor_payload, _remote_domain), do: {:error, :invalid_actor}

  defp remote_actor_public_key(actor_payload) when is_map(actor_payload) do
    normalize_optional_string(
      actor_payload["public_key"] ||
        actor_payload["public_key_pem"] ||
        get_in(actor_payload, ["publicKey", "publicKeyPem"]) ||
        get_in(actor_payload, ["public_key", "public_key_pem"])
    ) || "-----BEGIN PUBLIC KEY-----\nARBP_PLACEHOLDER\n-----END PUBLIC KEY-----\n"
  end

  defp upsert_remote_read_receipt(chat_message_id, remote_actor_id, remote_domain, read_at)
       when is_integer(chat_message_id) and is_integer(remote_actor_id) and
              is_binary(remote_domain) do
    attrs = %{
      chat_message_id: chat_message_id,
      remote_actor_id: remote_actor_id,
      origin_domain: String.downcase(remote_domain),
      read_at: read_at || DateTime.utc_now()
    }

    case Repo.get_by(FederationReadReceipt,
           chat_message_id: chat_message_id,
           remote_actor_id: remote_actor_id
         ) do
      nil ->
        %FederationReadReceipt{}
        |> FederationReadReceipt.changeset(attrs)
        |> Repo.insert()

      %FederationReadReceipt{} = receipt ->
        receipt
        |> FederationReadReceipt.changeset(attrs)
        |> Repo.update()
    end
  end

  defp upsert_remote_read_receipt(_chat_message_id, _remote_actor_id, _remote_domain, _read_at),
    do: {:error, :invalid_event_payload}

  defp maybe_broadcast_remote_read_receipt(chat_message_id, remote_actor_id, read_at)
       when is_integer(chat_message_id) and is_integer(remote_actor_id) do
    case {Repo.get(ChatMessage, chat_message_id), Repo.get(ActivityPubActor, remote_actor_id)} do
      {%ChatMessage{conversation_id: conversation_id}, %ActivityPubActor{} = actor} ->
        label =
          case normalize_optional_string(actor.display_name) do
            nil -> "@#{actor.username}@#{actor.domain}"
            display_name -> "#{display_name} (@#{actor.username}@#{actor.domain})"
          end

        broadcast_conversation_event(
          conversation_id,
          {:chat_remote_read_receipt,
           %{
             message_id: chat_message_id,
             remote_actor_id: remote_actor_id,
             username: label,
             avatar: actor.avatar_url,
             read_at: read_at
           }}
        )

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_broadcast_remote_read_receipt(_chat_message_id, _remote_actor_id, _read_at), do: :ok

  defp upsert_extension_projection(
         event_type,
         event_key,
         payload,
         remote_domain,
         server_id,
         conversation_id,
         occurred_at,
         status \\ nil
       )

  defp upsert_extension_projection(
         event_type,
         event_key,
         payload,
         remote_domain,
         server_id,
         conversation_id,
         occurred_at,
         status
       )
       when is_binary(event_type) and is_binary(event_key) and is_binary(remote_domain) and
              is_map(payload) do
    attrs = %{
      event_type: event_type,
      origin_domain: String.downcase(remote_domain),
      event_key: event_key,
      payload: payload,
      status: status,
      occurred_at: occurred_at || DateTime.utc_now(),
      server_id: server_id,
      conversation_id: conversation_id
    }

    case Repo.get_by(FederationExtensionEvent,
           event_type: event_type,
           origin_domain: String.downcase(remote_domain),
           event_key: event_key
         ) do
      nil ->
        %FederationExtensionEvent{}
        |> FederationExtensionEvent.changeset(attrs)
        |> Repo.insert()

      %FederationExtensionEvent{} = event ->
        event
        |> FederationExtensionEvent.changeset(attrs)
        |> Repo.update()
    end
  end

  defp upsert_extension_projection(
         _event_type,
         _event_key,
         _payload,
         _remote_domain,
         _server_id,
         _conversation_id,
         _occurred_at,
         _status
       ),
       do: {:error, :invalid_event_payload}

  defp upsert_extension_system_message(
         %Conversation{} = mirror_channel,
         event_type,
         event_key,
         content,
         metadata,
         remote_domain
       )
       when is_binary(event_type) and is_binary(event_key) and is_binary(content) and
              is_map(metadata) and is_binary(remote_domain) do
    federated_source = "arbp:ext:#{event_type}:#{event_key}"

    attrs = %{
      conversation_id: mirror_channel.id,
      content: content,
      message_type: "system",
      media_metadata: metadata,
      is_federated_mirror: true,
      origin_domain: String.downcase(remote_domain),
      federated_source: federated_source,
      sender_id: nil
    }

    case Repo.get_by(ChatMessage,
           conversation_id: mirror_channel.id,
           federated_source: federated_source
         ) do
      nil ->
        case %ChatMessage{} |> ChatMessage.changeset(attrs) |> Repo.insert() do
          {:ok, message} ->
            from(c in Conversation, where: c.id == ^mirror_channel.id)
            |> Repo.update_all(set: [last_message_at: message.inserted_at])

            maybe_broadcast_mirror_message_created(message)

          error ->
            error
        end

      %ChatMessage{} = existing ->
        update_attrs = %{
          content: content,
          media_metadata: metadata,
          edited_at: DateTime.utc_now()
        }

        case existing |> ChatMessage.changeset(update_attrs) |> Repo.update() do
          {:ok, message} ->
            from(c in Conversation, where: c.id == ^mirror_channel.id)
            |> Repo.update_all(set: [last_message_at: DateTime.utc_now()])

            maybe_broadcast_mirror_message_updated(message)

          error ->
            error
        end
    end
  end

  defp upsert_extension_system_message(
         _mirror_channel,
         _event_type,
         _event_key,
         _content,
         _metadata,
         _remote_domain
       ),
       do: {:error, :invalid_event_payload}

  defp upsert_presence_state(
         server_id,
         remote_actor_id,
         status,
         activities,
         updated_at,
         remote_domain
       )
       when is_integer(server_id) and is_integer(remote_actor_id) and is_binary(status) and
              is_binary(remote_domain) do
    attrs = %{
      server_id: server_id,
      remote_actor_id: remote_actor_id,
      status: status,
      origin_domain: String.downcase(remote_domain),
      updated_at_remote: updated_at || DateTime.utc_now(),
      activities: %{"items" => normalize_presence_activities(activities)}
    }

    case Repo.get_by(FederationPresenceState,
           server_id: server_id,
           remote_actor_id: remote_actor_id
         ) do
      nil ->
        %FederationPresenceState{}
        |> FederationPresenceState.changeset(attrs)
        |> Repo.insert()

      %FederationPresenceState{} = state ->
        state
        |> FederationPresenceState.changeset(attrs)
        |> Repo.update()
    end
  end

  defp upsert_presence_state(
         _server_id,
         _remote_actor_id,
         _status,
         _activities,
         _updated_at,
         _remote_domain
       ),
       do: {:error, :invalid_event_payload}

  defp maybe_broadcast_presence_update(server_id, remote_actor_id, status, activities, updated_at)
       when is_integer(server_id) and is_integer(remote_actor_id) and is_binary(status) do
    actor = Repo.get(ActivityPubActor, remote_actor_id)
    username = if actor, do: actor.username, else: "remote"
    domain = if actor, do: actor.domain, else: local_domain()
    handle = "@#{username}@#{domain}"

    label =
      case actor && normalize_optional_string(actor.display_name) do
        nil -> handle
        display_name -> "#{display_name} (#{handle})"
      end

    payload = %{
      server_id: server_id,
      remote_actor_id: remote_actor_id,
      handle: handle,
      label: label,
      avatar_url: if(actor, do: actor.avatar_url, else: nil),
      status: status,
      activities: normalize_presence_activities(activities),
      updated_at: updated_at || DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      PubSubTopics.users_presence(),
      {:federation_presence_update, payload}
    )

    :ok
  end

  defp maybe_broadcast_presence_update(
         _server_id,
         _remote_actor_id,
         _status,
         _activities,
         _updated_at
       ),
       do: :ok

  defp normalize_presence_activities(activities) when is_list(activities) do
    activities
    |> Enum.filter(&is_map/1)
    |> Enum.take(10)
  end

  defp normalize_presence_activities(%{"items" => activities}) when is_list(activities) do
    normalize_presence_activities(activities)
  end

  defp normalize_presence_activities(%{items: activities}) when is_list(activities) do
    normalize_presence_activities(activities)
  end

  defp normalize_presence_activities(_), do: []

  defp resolve_outbound_dm_handle(%ChatMessage{} = message, nil) do
    case Repo.get(Conversation, message.conversation_id) do
      %Conversation{} = conversation ->
        case remote_dm_handle_from_source(conversation.federated_source) do
          handle when is_binary(handle) -> {:ok, handle}
          _ -> {:error, :invalid_remote_handle}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp resolve_outbound_dm_handle(_message, remote_handle) when is_binary(remote_handle) do
    case normalize_remote_dm_handle(remote_handle) do
      {:ok, recipient} -> {:ok, recipient.handle}
      error -> error
    end
  end

  defp resolve_outbound_dm_handle(_message, _remote_handle), do: {:error, :invalid_remote_handle}

  defp resolve_local_dm_recipient(recipient_payload) when is_map(recipient_payload) do
    with {:ok, recipient} <- normalize_dm_actor_payload(recipient_payload, local_domain()),
         true <- recipient.domain == local_domain(),
         %User{} = local_user <- Accounts.get_user_by_username(recipient.username) do
      {:ok, local_user}
    else
      false -> {:error, :invalid_event_payload}
      nil -> {:error, :user_not_found}
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp resolve_local_dm_recipient(_), do: {:error, :invalid_event_payload}

  defp resolve_remote_dm_sender(sender_payload, remote_domain)
       when is_map(sender_payload) and is_binary(remote_domain) do
    normalized_remote_domain = String.downcase(remote_domain)

    with {:ok, sender} <- normalize_dm_actor_payload(sender_payload, normalized_remote_domain),
         true <- sender.domain == normalized_remote_domain do
      {:ok, sender}
    else
      false -> {:error, :origin_domain_mismatch}
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp resolve_remote_dm_sender(_sender_payload, _remote_domain),
    do: {:error, :invalid_event_payload}

  defp ensure_remote_dm_conversation(%User{} = local_user, remote_sender)
       when is_map(remote_sender) do
    remote_source = remote_dm_source(remote_sender.handle)

    existing_remote_dm =
      from(c in Conversation,
        join: cm in ConversationMember,
        on: c.id == cm.conversation_id,
        where:
          c.type == "dm" and c.federated_source == ^remote_source and
            cm.user_id == ^local_user.id and is_nil(cm.left_at),
        limit: 1
      )

    case Repo.one(existing_remote_dm) do
      %Conversation{} = conversation ->
        {:ok, conversation}

      nil ->
        case Repo.transaction(fn ->
               {:ok, conversation} =
                 %Conversation{}
                 |> Conversation.dm_changeset(%{
                   creator_id: local_user.id,
                   name: "@" <> remote_sender.handle,
                   avatar_url: remote_sender.avatar_url,
                   federated_source: remote_source
                 })
                 |> Repo.insert()

               {:ok, _member} =
                 ConversationMember.add_member_changeset(conversation.id, local_user.id, "member")
                 |> Repo.insert()

               from(c in Conversation, where: c.id == ^conversation.id)
               |> Repo.update_all(set: [member_count: 1])

               conversation
             end) do
          {:ok, conversation} ->
            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "user:#{local_user.id}",
              {:added_to_conversation, %{conversation_id: conversation.id}}
            )

            {:ok, conversation}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp ensure_remote_dm_conversation(_local_user, _remote_sender),
    do: {:error, :invalid_event_payload}

  defp upsert_remote_dm_message(
         %Conversation{} = conversation,
         message_payload,
         remote_domain,
         remote_sender
       )
       when is_map(message_payload) and is_binary(remote_domain) and is_map(remote_sender) do
    federation_message_id = normalize_optional_string(message_payload["id"])
    media_urls = normalize_media_urls(message_payload["media_urls"])
    content = normalize_optional_string(message_payload["content"])

    cond do
      !is_binary(federation_message_id) ->
        {:error, :invalid_event_payload}

      !is_binary(content) and media_urls == [] ->
        {:error, :invalid_event_payload}

      true ->
        case Repo.get_by(ChatMessage,
               conversation_id: conversation.id,
               federated_source: federation_message_id
             ) do
          %ChatMessage{} ->
            {:ok, :duplicate}

          nil ->
            message_metadata =
              case message_payload["media_metadata"] do
                %{} = metadata -> metadata
                _ -> %{}
              end

            attrs = %{
              conversation_id: conversation.id,
              sender_id: nil,
              content: content,
              message_type: normalize_message_type(message_payload["message_type"]),
              media_urls: media_urls,
              media_metadata:
                Map.put(
                  message_metadata,
                  "remote_sender",
                  remote_sender_metadata(remote_sender, message_payload["sender"])
                ),
              federated_source: federation_message_id,
              origin_domain: String.downcase(remote_domain),
              is_federated_mirror: true,
              edited_at: parse_datetime(message_payload["edited_at"])
            }

            with {:ok, inserted_message} <-
                   %ChatMessage{} |> ChatMessage.changeset(attrs) |> Repo.insert() do
              from(c in Conversation, where: c.id == ^conversation.id)
              |> Repo.update_all(set: [last_message_at: inserted_message.inserted_at])

              {:ok, inserted_message}
            end
        end
    end
  end

  defp upsert_remote_dm_message(_conversation, _message_payload, _remote_domain, _remote_sender),
    do: {:error, :invalid_event_payload}

  defp maybe_broadcast_remote_dm_message_created(
         _conversation,
         :duplicate,
         _local_user,
         _remote_sender
       ),
       do: :ok

  defp maybe_broadcast_remote_dm_message_created(
         %Conversation{} = conversation,
         %ChatMessage{} = message,
         %User{} = local_user,
         remote_sender
       )
       when is_map(remote_sender) do
    decrypted =
      case ChatMessages.get_message_decrypted(message.id) do
        %ChatMessage{} = hydrated -> hydrated
        _ -> message
      end

    broadcast_conversation_event(conversation.id, {:new_chat_message, decrypted})
    Elektrine.AppCache.invalidate_chat_cache(local_user.id)

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{local_user.id}",
      {:conversation_activity, %{conversation_id: conversation.id}}
    )

    maybe_notify_remote_dm_recipient(local_user, conversation, decrypted, remote_sender)
    :ok
  end

  defp maybe_broadcast_remote_dm_message_created(
         _conversation,
         _message,
         _local_user,
         _remote_sender
       ),
       do: :ok

  defp maybe_notify_remote_dm_recipient(
         %User{notify_on_direct_message: false},
         _conversation,
         _message,
         _remote_sender
       ),
       do: :ok

  defp maybe_notify_remote_dm_recipient(
         %User{} = local_user,
         %Conversation{} = conversation,
         %ChatMessage{} = message,
         remote_sender
       )
       when is_map(remote_sender) do
    title = "Message from @#{remote_sender.handle}"

    _ =
      Notifications.create_notification(%{
        user_id: local_user.id,
        actor_id: nil,
        type: "new_message",
        title: title,
        body: remote_dm_message_preview(message),
        url: "/chat/#{conversation.hash || conversation.id}#message-#{message.id}",
        source_type: "message",
        source_id: message.id,
        priority: "normal",
        metadata: %{"remote_sender" => remote_sender_metadata(remote_sender)}
      })

    :ok
  end

  defp maybe_notify_remote_dm_recipient(_local_user, _conversation, _message, _remote_sender),
    do: :ok

  defp remote_dm_message_preview(%ChatMessage{} = message) do
    cond do
      is_binary(normalize_optional_string(message.content)) ->
        message.content |> String.trim() |> String.slice(0, 140)

      (message.media_urls || []) != [] ->
        "Sent an attachment"

      true ->
        "New message"
    end
  end

  defp remote_dm_message_preview(_), do: "New message"

  defp remote_sender_metadata(remote_sender, sender_payload \\ nil)

  defp remote_sender_metadata(remote_sender, sender_payload) when is_map(remote_sender) do
    base =
      case sender_payload do
        %{} = payload -> payload
        _ -> %{}
      end

    base
    |> Map.put("username", remote_sender.username)
    |> Map.put("display_name", remote_sender.display_name || remote_sender.username)
    |> Map.put("domain", remote_sender.domain)
    |> Map.put("handle", remote_sender.handle)
    |> maybe_put_optional_map_value("avatar_url", remote_sender.avatar_url)
    |> maybe_put_optional_map_value("avatar", remote_sender.avatar_url)
  end

  defp remote_sender_metadata(_remote_sender, _sender_payload), do: %{}

  defp dm_actor_payload(recipient) when is_map(recipient) do
    username = Map.get(recipient, :username) || Map.get(recipient, "username")
    domain = Map.get(recipient, :domain) || Map.get(recipient, "domain")
    handle = Map.get(recipient, :handle) || Map.get(recipient, "handle")
    display_name = Map.get(recipient, :display_name) || Map.get(recipient, "display_name")
    avatar_url = Map.get(recipient, :avatar_url) || Map.get(recipient, "avatar_url")

    %{
      "username" => username,
      "display_name" => display_name || username,
      "domain" => domain,
      "handle" => handle
    }
    |> maybe_put_optional_map_value("avatar_url", avatar_url)
  end

  defp normalize_dm_actor_payload(payload, fallback_domain)
       when is_map(payload) and is_binary(fallback_domain) do
    normalized_fallback_domain = String.downcase(fallback_domain)
    raw_handle = normalize_optional_string(payload["handle"] || payload[:handle])
    raw_username = normalize_optional_string(payload["username"] || payload[:username])
    raw_domain = normalize_optional_string(payload["domain"] || payload[:domain])

    normalized_identity =
      cond do
        is_binary(raw_handle) ->
          normalize_remote_dm_handle(raw_handle)

        is_binary(raw_username) ->
          domain = raw_domain || normalized_fallback_domain
          normalize_remote_dm_handle("#{raw_username}@#{domain}")

        true ->
          {:error, :invalid_event_payload}
      end

    with {:ok, identity} <- normalized_identity do
      {:ok,
       %{
         username: identity.username,
         domain: identity.domain,
         handle: identity.handle,
         display_name:
           normalize_optional_string(payload["display_name"] || payload[:display_name]) ||
             identity.username,
         avatar_url:
           normalize_optional_string(
             payload["avatar_url"] || payload[:avatar_url] || payload["avatar"] ||
               payload[:avatar]
           )
       }}
    end
  end

  defp normalize_dm_actor_payload(_payload, _fallback_domain),
    do: {:error, :invalid_event_payload}

  defp normalize_remote_dm_handle(handle) when is_binary(handle) do
    normalized =
      handle
      |> String.trim()
      |> String.trim_leading("@")
      |> String.downcase()

    case Regex.run(~r/^([a-z0-9_]{1,64})@([a-z0-9.-]+\.[a-z]{2,})$/, normalized) do
      [_, username, domain] ->
        {:ok, %{username: username, domain: domain, handle: "#{username}@#{domain}"}}

      _ ->
        {:error, :invalid_remote_handle}
    end
  end

  defp normalize_remote_dm_handle(_), do: {:error, :invalid_remote_handle}

  defp remote_dm_source(handle), do: @remote_dm_source_prefix <> handle

  defp remote_dm_handle_from_source(source) when is_binary(source) do
    with true <- String.starts_with?(source, @remote_dm_source_prefix),
         {:ok, recipient} <-
           source
           |> String.replace_prefix(@remote_dm_source_prefix, "")
           |> normalize_remote_dm_handle() do
      recipient.handle
    else
      _ -> nil
    end
  end

  defp remote_dm_handle_from_source(_), do: nil

  defp normalize_media_urls(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(10)
  end

  defp normalize_media_urls(_), do: []

  defp maybe_put_optional_map_value(map, _key, nil), do: map

  defp maybe_put_optional_map_value(map, key, value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: map, else: Map.put(map, key, trimmed)
  end

  defp maybe_put_optional_map_value(map, _key, _value), do: map

  defp add_mirror_reaction(chat_message_id, remote_actor_id, emoji) do
    case Repo.get_by(ChatMessageReaction,
           chat_message_id: chat_message_id,
           remote_actor_id: remote_actor_id,
           emoji: emoji
         ) do
      nil ->
        %ChatMessageReaction{}
        |> ChatMessageReaction.changeset(%{
          chat_message_id: chat_message_id,
          remote_actor_id: remote_actor_id,
          emoji: emoji
        })
        |> Repo.insert()
        |> case do
          {:ok, reaction} -> {:ok, reaction}
          {:error, reason} -> {:error, reason}
        end

      _existing ->
        {:ok, :duplicate}
    end
  end

  defp remove_mirror_reaction(chat_message_id, remote_actor_id, emoji) do
    {removed_count, _} =
      from(r in ChatMessageReaction,
        where:
          r.chat_message_id == ^chat_message_id and
            r.remote_actor_id == ^remote_actor_id and
            r.emoji == ^emoji
      )
      |> Repo.delete_all()

    {:ok, removed_count}
  end

  defp maybe_broadcast_mirror_message_created(:duplicate), do: :ok

  defp maybe_broadcast_mirror_message_created(%ChatMessage{
         id: message_id,
         conversation_id: conversation_id
       }) do
    case ChatMessages.get_message_decrypted(message_id) do
      %ChatMessage{} = message ->
        broadcast_conversation_event(conversation_id, {:new_chat_message, message})

      _ ->
        :ok
    end
  end

  defp maybe_broadcast_mirror_message_created(_), do: :ok

  defp maybe_broadcast_mirror_message_updated(%ChatMessage{
         id: message_id,
         conversation_id: conversation_id
       }) do
    case ChatMessages.get_message_decrypted(message_id) do
      %ChatMessage{} = message ->
        broadcast_conversation_event(conversation_id, {:chat_message_updated, message})

      _ ->
        :ok
    end
  end

  defp maybe_broadcast_mirror_message_updated(_), do: :ok

  defp maybe_broadcast_mirror_message_deleted(message_id) when is_integer(message_id) do
    case Repo.get(ChatMessage, message_id) do
      %ChatMessage{conversation_id: conversation_id} ->
        broadcast_conversation_event(conversation_id, {:chat_message_deleted, message_id})

      _ ->
        :ok
    end
  end

  defp maybe_broadcast_mirror_message_deleted(_), do: :ok

  defp maybe_broadcast_mirror_reaction_added(_message_id, :duplicate), do: :ok

  defp maybe_broadcast_mirror_reaction_added(message_id, %ChatMessageReaction{} = reaction) do
    case Repo.get(ChatMessage, message_id) do
      %ChatMessage{conversation_id: conversation_id} ->
        reaction = Repo.preload(reaction, [:user, :remote_actor])

        broadcast_conversation_event(
          conversation_id,
          {:chat_reaction_added, message_id, reaction}
        )

      _ ->
        :ok
    end
  end

  defp maybe_broadcast_mirror_reaction_added(_message_id, _reaction), do: :ok

  defp maybe_broadcast_mirror_reaction_removed(
         _message_id,
         _remote_actor_id,
         _emoji,
         removed_count
       )
       when removed_count <= 0,
       do: :ok

  defp maybe_broadcast_mirror_reaction_removed(message_id, remote_actor_id, emoji, _removed_count) do
    case Repo.get(ChatMessage, message_id) do
      %ChatMessage{conversation_id: conversation_id} ->
        broadcast_conversation_event(
          conversation_id,
          {:chat_reaction_removed, message_id, nil, emoji, remote_actor_id}
        )

      _ ->
        :ok
    end
  end

  defp broadcast_conversation_event(conversation_id, event) do
    topic = PubSubTopics.conversation(conversation_id)
    Phoenix.PubSub.broadcast(Elektrine.PubSub, topic, event)
  end

  defp publish_latest_message_event(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{type: "channel", server_id: server_id} when not is_nil(server_id) ->
        case Repo.get(Server, server_id) do
          %Server{is_federated_mirror: false} ->
            from(m in ChatMessage,
              where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at),
              order_by: [desc: m.inserted_at],
              limit: 1
            )
            |> Repo.one()
            |> case do
              nil -> :ok
              latest -> publish_message_created(latest)
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp outbound_signing_material(peer) do
    active_key_id = peer.active_outbound_key_id

    case Enum.find(peer.keys, fn key -> key.id == active_key_id and is_binary(key.private_key) end) do
      %{id: id, private_key: private_key} ->
        {id, private_key}

      _ ->
        peer.keys
        |> Enum.find(&is_binary(&1.private_key))
        |> case do
          %{id: id, private_key: private_key} -> {id, private_key}
          _ -> local_event_signing_material()
        end
    end
  end

  defp incoming_verification_materials_for_key_id(peer, key_id) do
    case normalize_optional_string(key_id) do
      nil ->
        peer.keys
        |> Enum.map(&key_verification_material/1)
        |> Enum.reject(&is_nil/1)

      requested_key_id ->
        peer.keys
        |> Enum.filter(&(key_id_for(&1) == requested_key_id))
        |> Enum.map(&key_verification_material/1)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp key_verification_material(key) when is_map(key) do
    Map.get(key, :public_key) || Map.get(key, "public_key") || Map.get(key, :secret) ||
      Map.get(key, "secret")
  end

  defp key_verification_material(_), do: nil

  defp key_id_for(key) when is_map(key) do
    Map.get(key, :id) || Map.get(key, "id")
  end

  defp key_id_for(_), do: nil

  defp local_event_signing_material do
    key_id = local_identity_key_id()

    case local_identity_keys() |> Enum.find(&(&1.id == key_id and is_binary(&1.private_key))) do
      %{id: id, private_key: private_key} ->
        {id, private_key}

      _ ->
        case local_identity_keys() |> Enum.find(&is_binary(&1.private_key)) do
          %{id: id, private_key: private_key} ->
            {id, private_key}

          _ ->
            derived_key_seed_source =
              federation_config()
              |> Keyword.get(
                :identity_shared_secret,
                "#{local_domain()}:#{key_id}"
              )

            {_public_key, private_key} =
              ArblargSDK.derive_keypair_from_secret(derived_key_seed_source)

            {key_id, private_key}
        end
    end
  end

  defp normalize_incoming_event_payload(payload) when is_map(payload) do
    payload_data = payload["payload"] || payload["data"] || %{}

    protocol =
      if is_binary(payload["protocol"]), do: payload["protocol"], else: ArblargSDK.protocol_name()

    protocol_id =
      if is_binary(payload["protocol_id"]),
        do: payload["protocol_id"],
        else: ArblargSDK.protocol_id()

    protocol_version =
      cond do
        is_binary(payload["protocol_version"]) ->
          payload["protocol_version"]

        payload["version"] in [1, "1"] ->
          ArblargSDK.protocol_version()

        true ->
          nil
      end

    payload
    |> Map.put_new("protocol", protocol)
    |> Map.put_new("protocol_id", protocol_id)
    |> Map.put_new(
      "protocol_label",
      "#{protocol_id}/#{protocol_version || ArblargSDK.protocol_version()}"
    )
    |> Map.put("payload", payload_data)
    |> Map.put("data", payload_data)
    |> Map.put_new("idempotency_key", payload["event_id"])
    |> Map.put_new(
      "sent_at",
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    )
    |> then(fn normalized ->
      if is_binary(protocol_version) do
        Map.put(normalized, "protocol_version", protocol_version)
      else
        normalized
      end
    end)
  end

  defp normalize_incoming_event_payload(payload), do: payload
  defp delivery_concurrency do
    Config.delivery_concurrency(federation_config())
  end

  defp outbound_events_url(peer) do
    Config.outbound_events_url(peer)
  end

  defp outbound_sync_url(peer) do
    Config.outbound_sync_url(peer)
  end

  defp outbound_snapshot_url(peer, remote_server_id) do
    Config.outbound_snapshot_url(peer, remote_server_id)
  end

  defp delivery_timeout_ms do
    Config.delivery_timeout_ms(federation_config())
  end

  defp outbox_max_attempts do
    Config.outbox_max_attempts(federation_config())
  end

  defp outbox_backoff_seconds(attempt_count) do
    Config.outbox_backoff_seconds(federation_config(), attempt_count)
  end

  defp outbox_partition_month(%DateTime{} = datetime) do
    Config.outbox_partition_month(datetime)
  end

  defp archive_old_events do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-event_retention_days() * 86_400, :second)
      |> DateTime.truncate(:second)

    sql =
      "INSERT INTO messaging_federation_events_archive (\n  protocol_version,\n  event_id,\n  idempotency_key,\n  origin_domain,\n  event_type,\n  stream_id,\n  sequence,\n  payload,\n  received_at,\n  partition_month,\n  inserted_at\n)\nSELECT\n  protocol_version,\n  event_id,\n  idempotency_key,\n  origin_domain,\n  event_type,\n  stream_id,\n  sequence,\n  payload,\n  received_at,\n  date_trunc('month', inserted_at)::date,\n  inserted_at\nFROM messaging_federation_events\nWHERE inserted_at < $1\nON CONFLICT (event_id) DO NOTHING\n"

    _ = Ecto.Adapters.SQL.query(Repo, sql, [cutoff])
    {_deleted, _} = Repo.delete_all(from(e in FederationEvent, where: e.inserted_at < ^cutoff))
    :ok
  end

  defp prune_old_outbox_rows do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-outbox_retention_days() * 86_400, :second)
      |> DateTime.truncate(:second)

    {_deleted, _} =
      Repo.delete_all(
        from(o in FederationOutboxEvent,
          where: o.updated_at < ^cutoff and o.status in ["delivered", "failed"]
        )
      )

    :ok
  end

  defp prune_request_replays do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {_deleted, _} =
      Repo.delete_all(from(r in FederationRequestReplay, where: r.expires_at < ^now))

    :ok
  end

  defp event_retention_days do
    Config.event_retention_days(federation_config())
  end

  defp outbox_retention_days do
    Config.outbox_retention_days(federation_config())
  end

  defp replay_nonce_ttl_seconds do
    Config.replay_nonce_ttl_seconds(federation_config(), @clock_skew_seconds)
  end

  defp allow_insecure_transport? do
    Config.allow_insecure_transport?(federation_config())
  end

  defp clock_skew_seconds do
    Config.clock_skew_seconds(federation_config(), @clock_skew_seconds)
  end

  defp federation_config do
    Application.get_env(:elektrine, :messaging_federation, [])
  end

  defp local_base_url do
    Config.local_base_url(federation_config(), local_domain())
  end

  defp local_identity_key_id do
    Config.local_identity_key_id(federation_config())
  end

  defp local_identity_discovery_identity do
    Config.local_identity_discovery_identity(local_identity_keys(), local_identity_key_id())
  end

  defp local_identity_keys do
    Config.local_identity_keys(
      federation_config(),
      local_identity_key_id(),
      local_domain(),
      enabled?(),
      prod_environment?()
    )
  end

  defp prod_environment? do
    Application.get_env(:elektrine, :environment) == :prod
  end

  defp official_relay_operator do
    Config.official_relay_operator(federation_config())
  end

  defp discovery_official_relays do
    Config.discovery_official_relays(federation_config())
  end

  defp configured_peers do
    Config.configured_peers(federation_config(), allow_insecure_transport?())
  end

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      trimmed
    end
  end

  defp normalize_optional_string(_) do
    nil
  end
end
