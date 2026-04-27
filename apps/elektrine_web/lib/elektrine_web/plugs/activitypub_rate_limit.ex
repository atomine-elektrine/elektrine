defmodule ElektrineWeb.Plugs.ActivityPubRateLimit do
  @moduledoc """
  Early ActivityPub rate limiting for inbox endpoints.

  This plug runs before HTTP signature verification so we can reject abusive
  traffic before expensive key fetch and signature checks hit the database.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Elektrine.ActivityPub.InboxRateLimiter
  alias ElektrineWeb.ClientIP

  def init(opts), do: opts

  def call(conn, _opts) do
    if inbox_request?(conn) do
      ip = get_client_ip(conn)

      case InboxRateLimiter.check_rate_limit(ip) do
        {:ok, :allowed} ->
          assign(conn, :activitypub_rate_limit_checked, true)

        {:error, :rate_limited} ->
          conn
          |> put_status(:too_many_requests)
          |> json(%{error: "Rate limited"})
          |> halt()
      end
    else
      conn
    end
  end

  defp inbox_request?(%Plug.Conn{method: "POST", request_path: request_path}) do
    String.ends_with?(request_path, "/inbox")
  end

  defp inbox_request?(_), do: false

  defp get_client_ip(conn), do: ClientIP.client_ip(conn)
end
