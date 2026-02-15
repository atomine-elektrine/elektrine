defmodule ElektrineWeb.MessagingFederationController do
  @moduledoc """
  Endpoints for cross-instance messaging federation sync.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Messaging.Federation

  @doc """
  GET /.well-known/elektrine-messaging-federation
  Public discovery metadata for cross-domain bootstrap.
  """
  def well_known(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(Federation.local_discovery_document())
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
