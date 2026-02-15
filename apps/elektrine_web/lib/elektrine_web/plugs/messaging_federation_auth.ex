defmodule ElektrineWeb.Plugs.MessagingFederationAuth do
  @moduledoc """
  Authenticates incoming messaging federation requests from trusted peers.

  Required headers:
  - x-elektrine-federation-domain
  - x-elektrine-federation-key-id (optional during rotation fallback)
  - x-elektrine-federation-timestamp
  - x-elektrine-federation-signature
  """

  import Plug.Conn
  require Logger

  alias Elektrine.Messaging.Federation

  def init(opts), do: opts

  def call(conn, _opts) do
    if Federation.enabled?() do
      authenticate(conn)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(:forbidden, Jason.encode!(%{error: "Messaging federation is disabled"}))
      |> halt()
    end
  end

  defp authenticate(conn) do
    domain = get_req_header(conn, "x-elektrine-federation-domain") |> List.first()
    key_id = get_req_header(conn, "x-elektrine-federation-key-id") |> List.first()
    timestamp = get_req_header(conn, "x-elektrine-federation-timestamp") |> List.first()
    signature = get_req_header(conn, "x-elektrine-federation-signature") |> List.first()
    peer = if is_binary(domain), do: Federation.incoming_peer(domain), else: nil

    cond do
      !is_binary(domain) ->
        reject(conn, :missing_domain)

      !is_binary(timestamp) ->
        reject(conn, :missing_timestamp)

      !is_binary(signature) ->
        reject(conn, :missing_signature)

      !Federation.valid_timestamp?(timestamp) ->
        reject(conn, :invalid_timestamp)

      is_nil(peer) ->
        reject(conn, {:unknown_peer, domain})

      !Federation.verify_signature(
        peer,
        domain,
        conn.method,
        conn.request_path,
        conn.query_string || "",
        timestamp,
        key_id,
        signature
      ) ->
        reject(conn, :invalid_signature)

      true ->
        conn
        |> assign(:federation_peer, peer)
        |> assign(:federation_peer_domain, domain)
        |> assign(:federation_peer_key_id, key_id)
    end
  end

  defp reject(conn, reason) do
    Logger.debug(
      "Messaging federation auth rejected: #{inspect(reason)} method=#{conn.method} path=#{conn.request_path}"
    )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, Jason.encode!(%{error: "Invalid federation signature"}))
    |> halt()
  end
end
