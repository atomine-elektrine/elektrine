defmodule ElektrineWeb.MessagingFederationController do
  @moduledoc """
  Endpoints for cross-instance messaging federation sync.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.Federation

  @discovery_cache_control "public, max-age=300, stale-while-revalidate=60"
  @schema_cache_control "public, max-age=3600, stale-while-revalidate=300"

  @doc """
  GET /.well-known/arblarg
  Public discovery metadata for cross-domain bootstrap.

  Legacy aliases are still served for compatibility.
  """
  def well_known(conn, _params) do
    payload = Federation.local_discovery_document()

    conn
    |> put_cache_headers(payload, @discovery_cache_control)
    |> put_status(:ok)
    |> json(payload)
  end

  @doc """
  GET /.well-known/arblarg/:version
  Version-pinned discovery metadata.
  """
  def well_known_versioned(conn, %{"version" => version}) do
    if version == ArblargSDK.protocol_version() do
      payload = Federation.local_discovery_document(version)

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
  GET /federation/messaging/arblarg/:version/schemas/:name
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
  GET /federation/messaging/arblarg/profiles
  Returns ARBP profile badges and extension registry information.
  """
  def profiles(conn, _params) do
    payload = Federation.arblarg_profiles_document()

    conn
    |> put_cache_headers(payload, @discovery_cache_control)
    |> put_status(:ok)
    |> json(payload)
  end

  defp schema_name_from_params(%{"name" => name, "format" => format})
       when is_binary(name) and is_binary(format) do
    name <> "." <> format
  end

  defp schema_name_from_params(%{"name" => name}) when is_binary(name), do: name

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

  @doc """
  POST /federation/messaging/events
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
          {:ok, :recovered} ->
            conn
            |> put_status(:accepted)
            |> json(%{status: "recovered_via_snapshot"})

          {:error, _reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: "Sequence gap for stream"})
        end

      {:error, :unsupported_event_type} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Unsupported event type"})

      {:error, :unsupported_version} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Unsupported federation payload version"})

      {:error, :unsupported_protocol} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Unsupported federation protocol identifier"})

      {:error, :origin_domain_mismatch} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Origin domain mismatch"})

      {:error, :invalid_payload} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid payload"})

      {:error, :invalid_event_payload} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid event payload"})

      {:error, :invalid_idempotency_key} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid idempotency key"})

      {:error, :invalid_event_signature} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid event signature"})

      {:error, :federation_origin_conflict} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Federation origin conflict for mirrored resource"})

      {:error, {:post_recovery_apply_failed, :federation_origin_conflict}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Federation origin conflict for mirrored resource"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to process event: #{inspect(reason)}"})
    end
  end

  @doc """
  POST /federation/messaging/sync
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
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Origin domain mismatch"})

      {:error, :invalid_payload} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid payload"})

      {:error, :invalid_server_payload} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid server payload"})

      {:error, :federation_origin_conflict} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Federation origin conflict for mirrored resource"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to import snapshot: #{inspect(reason)}"})
    end
  end

  @doc """
  GET /federation/messaging/servers/:server_id/snapshot
  Exports a local server snapshot for trusted peers.
  """
  def snapshot(conn, %{"server_id" => server_id}) do
    case Integer.parse(server_id) do
      {id, ""} ->
        case Federation.build_server_snapshot(id) do
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
end
