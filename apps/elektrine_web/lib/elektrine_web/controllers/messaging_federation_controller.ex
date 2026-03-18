defmodule ElektrineWeb.MessagingFederationController do
  @moduledoc """
  Endpoints for cross-instance messaging federation sync.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Domains
  alias Elektrine.Constants
  alias Elektrine.Messaging
  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Federation.{Contexts, Discovery, Peers, Protocol, Runtime, Utils}
  alias Elektrine.Messaging.FederationSessionWebSock
  alias WebSockAdapter

  @discovery_cache_control "public, max-age=300, stale-while-revalidate=60"
  @schema_cache_control "public, max-age=3600, stale-while-revalidate=300"

  @doc """
  GET /.well-known/_arblarg
  Public discovery metadata for cross-domain bootstrap.
  """
  def well_known(conn, _params) do
    payload = local_discovery_document_for_request(conn)

    conn
    |> put_cache_headers(payload, @discovery_cache_control)
    |> put_status(:ok)
    |> json(payload)
  end

  @doc """
  GET /.well-known/_arblarg/:version
  Version-pinned discovery metadata.
  """
  def well_known_versioned(conn, %{"version" => version}) do
    if version == ArblargSDK.protocol_version() do
      payload = local_discovery_document_for_request(conn, version)

      conn
      |> put_cache_headers(payload, @discovery_cache_control)
      |> put_status(:ok)
      |> json(payload)
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "Unsupported Arblarg protocol version"})
    end
  end

  @doc """
  GET /_arblarg/:version/schemas/:name
  Returns JSON Schema documents for Arblarg protocol artifacts.
  """
  def schema(conn, %{"version" => version} = params) do
    case ArblargSDK.schema(version, schema_name_from_params(params)) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Schema not found"})

      schema ->
        conn
        |> put_cache_headers(schema, @schema_cache_control)
        |> put_status(:ok)
        |> json(schema)
    end
  end

  @doc """
  GET /_arblarg/profiles
  Returns Arblarg profile badges and extension registry information.
  """
  def profiles(conn, _params) do
    payload = Federation.arblarg_profiles_document()

    conn
    |> put_cache_headers(payload, @discovery_cache_control)
    |> put_status(:ok)
    |> json(payload)
  end

  @doc """
  GET /_arblarg/servers/public
  Public directory of local public servers for cross-instance discovery.
  """
  def public_servers(conn, params) do
    limit = parse_int(params["limit"], 50)
    query = normalize_search_query(params["query"])

    servers = Messaging.list_public_directory_servers(limit: limit, query: query)

    payload = %{
      version: 1,
      origin_domain: Federation.local_domain(),
      servers: Enum.map(servers, &format_public_server/1)
    }

    conn
    |> put_cache_headers(payload, @discovery_cache_control)
    |> put_status(:ok)
    |> json(payload)
  end

  @doc """
  GET /_arblarg/session
  Upgrades an authenticated federation connection to the transport-neutral
  websocket session profile.
  """
  def session_websocket(conn, _params) do
    conn
    |> maybe_put_session_subprotocol()
    |> WebSockAdapter.upgrade(
      FederationSessionWebSock,
      %{
        remote_domain: conn.assigns.federation_peer_domain,
        peer: conn.assigns[:federation_peer]
      },
      timeout: Constants.websocket_timeout()
    )
    |> halt()
  end

  defp schema_name_from_params(%{"name" => name, "format" => format})
       when is_binary(name) and is_binary(format) do
    name <> "." <> format
  end

  defp schema_name_from_params(%{"name" => name}) when is_binary(name), do: name

  defp local_discovery_document_for_request(conn, version \\ ArblargSDK.protocol_version()) do
    case custom_profile_origin_domain(conn) do
      nil ->
        Federation.local_discovery_document(version)

      origin_domain ->
        Protocol.local_discovery_document(version, custom_discovery_context(origin_domain))
    end
  end

  defp custom_discovery_context(origin_domain) when is_binary(origin_domain) do
    %{
      local_domain: origin_domain,
      identity: Runtime.local_identity_discovery_identity(),
      base_url: base_url_for_origin_domain(origin_domain),
      allow_insecure_transport: Runtime.allow_insecure_transport?(),
      limits: Federation.discovery_limits_for_transport(),
      cache_ttl_seconds: Runtime.discovery_ttl_seconds(),
      official_relay_operator: Runtime.official_relay_operator(),
      official_relays: Runtime.discovery_official_relays(),
      clock_skew_seconds: Runtime.clock_skew_seconds(),
      sign_fun: &Discovery.sign_discovery_document(&1, discovery_context())
    }
  end

  defp discovery_context do
    Contexts.discovery(%{
      peers: &Peers.peers/0,
      truncate: &Utils.truncate/1
    })
  end

  defp custom_profile_origin_domain(conn) do
    case Domains.profile_custom_domain_for_host(conn.host) do
      %{domain: domain} when is_binary(domain) -> domain
      _ -> nil
    end
  end

  defp base_url_for_origin_domain(origin_domain) when is_binary(origin_domain) do
    case URI.parse(Runtime.local_base_url()) do
      %URI{} = uri ->
        uri
        |> Map.put(:host, origin_domain)
        |> URI.to_string()
        |> String.trim_trailing("/")

      _ ->
        "https://#{origin_domain}"
    end
  end

  defp put_cache_headers(conn, payload, cache_control) do
    encoded_payload = Jason.encode!(payload)

    etag =
      encoded_payload
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    conn
    |> put_resp_header("cache-control", cache_control)
    |> put_resp_header("etag", ~s(W/"#{etag}"))
  end

  defp format_public_server(server) do
    %{
      server_id: server.id,
      federation_id: server.federation_id,
      name: server.name,
      description: server.description,
      icon_url: server.icon_url,
      is_public: server.is_public,
      member_count: server.member_count,
      origin_domain: Federation.local_domain()
    }
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp normalize_search_query(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_search_query(_value), do: nil

  @doc """
  POST /_arblarg/events
  Imports a single ordered/idempotent event from a trusted peer.
  """
  def event(conn, payload) do
    remote_domain = conn.assigns[:federation_peer_domain]

    case Federation.receive_event(payload, remote_domain) do
      {:ok, :applied} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "applied"})

      {:ok, :duplicate} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "duplicate"})

      {:ok, :stale} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "stale"})

      {:error, :sequence_gap} ->
        case Federation.recover_sequence_gap(payload, remote_domain) do
          {:ok, :recovered_via_stream} ->
            conn
            |> put_status(:accepted)
            |> json(%{status: "recovered_via_stream"})

          {:ok, :recovered} ->
            conn
            |> put_status(:accepted)
            |> json(%{status: "recovered_via_snapshot"})

          {:ok, :recovered_via_snapshot} ->
            conn
            |> put_status(:accepted)
            |> json(%{status: "recovered_via_snapshot"})

          {:error, _reason} ->
            render_error(conn, :conflict, :sequence_gap, "Sequence gap for stream")
        end

      {:error, :unsupported_event_type} ->
        render_error(
          conn,
          :unprocessable_entity,
          :unsupported_event_type,
          "Unsupported event type"
        )

      {:error, :unsupported_version} ->
        render_error(
          conn,
          :bad_request,
          :unsupported_version,
          "Unsupported federation payload version"
        )

      {:error, :unsupported_protocol} ->
        render_error(
          conn,
          :bad_request,
          :unsupported_protocol,
          "Unsupported federation protocol identifier"
        )

      {:error, :origin_domain_mismatch} ->
        render_error(conn, :bad_request, :origin_domain_mismatch, "Origin domain mismatch")

      {:error, :origin_actor_domain_mismatch} ->
        render_error(
          conn,
          :bad_request,
          :origin_actor_domain_mismatch,
          "Origin actor domain mismatch"
        )

      {:error, :origin_identifier_host_mismatch} ->
        render_error(
          conn,
          :bad_request,
          :origin_identifier_host_mismatch,
          "Origin-owned identifier host mismatch"
        )

      {:error, :origin_stream_host_mismatch} ->
        render_error(
          conn,
          :bad_request,
          :origin_stream_host_mismatch,
          "Origin-owned stream host mismatch"
        )

      {:error, :invalid_payload} ->
        render_error(conn, :bad_request, :invalid_payload, "Invalid payload")

      {:error, :invalid_event_payload} ->
        render_error(conn, :bad_request, :invalid_event_payload, "Invalid event payload")

      {:error, :invalid_idempotency_key} ->
        render_error(conn, :bad_request, :invalid_idempotency_key, "Invalid idempotency key")

      {:error, :invalid_event_signature} ->
        render_error(conn, :bad_request, :invalid_event_signature, "Invalid event signature")

      {:error, :federation_origin_conflict} ->
        render_error(
          conn,
          :conflict,
          :federation_origin_conflict,
          "Federation origin conflict for mirrored resource"
        )

      {:error, :not_authorized_for_room} ->
        render_error(
          conn,
          :forbidden,
          :not_authorized_for_room,
          "Remote actor is not authorized for this room"
        )

      {:error, {:post_recovery_apply_failed, :federation_origin_conflict}} ->
        render_error(
          conn,
          :conflict,
          :federation_origin_conflict,
          "Federation origin conflict for mirrored resource"
        )

      {:error, {:post_recovery_apply_failed, :not_authorized_for_room}} ->
        render_error(
          conn,
          :forbidden,
          :not_authorized_for_room,
          "Remote actor is not authorized for this room"
        )

      {:error, reason} ->
        render_error(
          conn,
          :unprocessable_entity,
          reason,
          "Failed to process event: #{inspect(reason)}"
        )
    end
  end

  @doc """
  POST /_arblarg/events/batch
  Imports a signed batch of ordered/idempotent events from a trusted peer.
  """
  def event_batch(conn, payload) do
    remote_domain = conn.assigns[:federation_peer_domain]

    with {:ok, decoded_payload} <- decode_request_payload(conn, payload),
         {:ok, response} <- Federation.receive_event_batch(decoded_payload, remote_domain) do
      render_federation_payload(conn, :ok, response, :batch)
    else
      {:error, :invalid_payload} ->
        render_error(conn, :bad_request, :invalid_payload, "Invalid payload")

      {:error, :batch_limit_exceeded} ->
        render_error(
          conn,
          :unprocessable_entity,
          :batch_limit_exceeded,
          "Event batch exceeds the negotiated limit"
        )

      {:error, reason} ->
        render_error(
          conn,
          :unprocessable_entity,
          reason,
          "Failed to process event batch: #{inspect(reason)}"
        )
    end
  end

  @doc """
  POST /_arblarg/ephemeral
  Imports ephemeral presence and typing updates from a trusted peer.
  """
  def ephemeral(conn, payload) do
    remote_domain = conn.assigns[:federation_peer_domain]

    with {:ok, decoded_payload} <- decode_request_payload(conn, payload),
         {:ok, response} <- Federation.receive_ephemeral_batch(decoded_payload, remote_domain) do
      render_federation_payload(conn, :ok, response, :ephemeral)
    else
      {:error, :invalid_payload} ->
        render_error(conn, :bad_request, :invalid_payload, "Invalid payload")

      {:error, :ephemeral_limit_exceeded} ->
        render_error(
          conn,
          :unprocessable_entity,
          :ephemeral_limit_exceeded,
          "Ephemeral batch exceeds the negotiated limit"
        )

      {:error, reason} ->
        render_error(
          conn,
          :unprocessable_entity,
          reason,
          "Failed to process ephemeral payload: #{inspect(reason)}"
        )
    end
  end

  @doc """
  POST /_arblarg/sync
  Imports a server snapshot from a trusted peer.
  """
  def sync(conn, payload) do
    remote_domain = conn.assigns[:federation_peer_domain]

    case Federation.import_server_snapshot(payload, remote_domain) do
      {:ok, mirror_server} ->
        conn
        |> put_status(:ok)
        |> json(%{
          status: "ok",
          mirror_server_id: mirror_server.id,
          remote_domain: remote_domain
        })

      {:error, :unsupported_version} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Unsupported federation payload version"})

      {:error, :origin_domain_mismatch} ->
        render_error(conn, :bad_request, :origin_domain_mismatch, "Origin domain mismatch")

      {:error, :invalid_payload} ->
        render_error(conn, :bad_request, :invalid_payload, "Invalid payload")

      {:error, :invalid_server_payload} ->
        render_error(conn, :bad_request, :invalid_server_payload, "Invalid server payload")

      {:error, :invalid_snapshot_stream_positions} ->
        render_error(
          conn,
          :bad_request,
          :invalid_snapshot_stream_positions,
          "Invalid snapshot stream positions"
        )

      {:error, :invalid_snapshot_signature} ->
        render_error(
          conn,
          :bad_request,
          :invalid_snapshot_signature,
          "Invalid snapshot signature"
        )

      {:error, :invalid_snapshot_governance} ->
        render_error(
          conn,
          :bad_request,
          :invalid_snapshot_governance,
          "Invalid snapshot governance payload"
        )

      {:error, :snapshot_limit_exceeded} ->
        render_error(
          conn,
          :unprocessable_entity,
          :snapshot_limit_exceeded,
          "Snapshot exceeds negotiated limits"
        )

      {:error, :federation_origin_conflict} ->
        render_error(
          conn,
          :conflict,
          :federation_origin_conflict,
          "Federation origin conflict for mirrored resource"
        )

      {:error, reason} ->
        render_error(
          conn,
          :unprocessable_entity,
          reason,
          "Failed to import snapshot: #{inspect(reason)}"
        )
    end
  end

  @doc """
  GET /_arblarg/servers/:server_id/snapshot
  Exports a local server snapshot for trusted peers.
  """
  def snapshot(conn, %{"server_id" => server_id}) do
    case Integer.parse(server_id) do
      {id, ""} ->
        case Federation.build_server_snapshot(id, peer: conn.assigns[:federation_peer]) do
          {:ok, payload} ->
            conn
            |> put_status(:ok)
            |> json(payload)

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Server not found"})

          {:error, :federated_mirror} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Cannot export mirrored server snapshot"})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to build snapshot: #{inspect(reason)}"})
        end

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid server_id"})
    end
  end

  @doc """
  GET /_arblarg/streams/events
  Exports local ordered events for a single stream after a cursor.
  """
  def stream_events(conn, params) do
    stream_id = params["stream_id"]
    after_sequence = parse_positive_int(params["after_sequence"], 0)
    limit = parse_positive_int(params["limit"], 128)

    if is_binary(stream_id) and String.trim(stream_id) != "" do
      payload =
        Federation.export_stream_events(stream_id,
          after_sequence: after_sequence,
          limit: limit,
          peer: conn.assigns[:federation_peer]
        )

      conn
      |> put_status(:ok)
      |> json(payload)
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Invalid stream_id"})
    end
  end

  defp parse_positive_int(nil, default), do: default

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp parse_positive_int(_value, default), do: default

  defp decode_request_payload(conn, payload) do
    case request_format(conn) do
      :cbor ->
        conn.assigns[:raw_body]
        |> decode_cbor_payload()

      :json ->
        if is_map(payload) or is_list(payload),
          do: {:ok, payload},
          else: {:error, :invalid_payload}
    end
  end

  defp render_federation_payload(conn, status, payload, kind) do
    case request_format(conn) do
      :cbor ->
        content_type =
          case kind do
            :ephemeral -> "application/arblarg-ephemeral+cbor"
            _ -> "application/arblarg-batch+cbor"
          end

        conn
        |> put_resp_content_type(content_type)
        |> send_resp(status, CBOR.encode(payload))

      :json ->
        conn
        |> put_status(status)
        |> json(payload)
    end
  end

  defp request_format(conn) do
    content_type = get_req_header(conn, "content-type") |> List.first() |> to_string()

    cond do
      String.starts_with?(content_type, "application/arblarg-batch+cbor") -> :cbor
      String.starts_with?(content_type, "application/arblarg-ephemeral+cbor") -> :cbor
      true -> :json
    end
  end

  defp decode_cbor_payload(body) when is_binary(body) do
    case CBOR.decode(body) do
      {:ok, decoded, ""} -> {:ok, decoded}
      {:ok, _decoded, _rest} -> {:error, :invalid_payload}
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  defp decode_cbor_payload(_body), do: {:error, :invalid_payload}

  defp maybe_put_session_subprotocol(conn) do
    requested_subprotocol? =
      conn
      |> get_req_header("sec-websocket-protocol")
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)
      |> Enum.member?("arblarg.session.v1")

    if requested_subprotocol? do
      put_resp_header(conn, "sec-websocket-protocol", "arblarg.session.v1")
    else
      conn
    end
  end

  defp render_error(conn, status, reason, message) do
    conn
    |> put_status(status)
    |> json(%{error: message, code: Federation.error_code(reason)})
  end
end
