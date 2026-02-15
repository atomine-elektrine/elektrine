defmodule ElektrineWeb.Plugs.DAVRateLimit do
  @moduledoc """
  Rate limiting plug for CalDAV/CardDAV endpoints.

  Uses IP address for unauthenticated requests (auth failures)
  and user ID for authenticated requests.

  DAV clients typically sync frequently, so limits are more generous
  than API limits, but still protect against abuse.
  """
  import Plug.Conn

  alias Elektrine.DAV.RateLimiter

  def init(opts), do: opts

  def call(conn, _opts) do
    identifier = get_identifier(conn)

    case RateLimiter.check_rate_limit(identifier) do
      {:ok, :allowed} ->
        RateLimiter.record_attempt(identifier)
        conn

      {:error, {:rate_limited, retry_after, _reason}} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> send_resp(429, "Too many requests. Please retry after #{retry_after} seconds.")
        |> halt()
    end
  end

  # Use user_id if authenticated, otherwise fall back to IP
  defp get_identifier(conn) do
    case conn.assigns[:current_user] do
      %{id: user_id} -> "user:#{user_id}"
      _ -> "ip:#{get_client_ip(conn)}"
    end
  end

  defp get_client_ip(conn) do
    forwarded_for = get_req_header(conn, "x-forwarded-for") |> List.first()
    real_ip = get_req_header(conn, "x-real-ip") |> List.first()

    cond do
      forwarded_for ->
        forwarded_for
        |> String.split(",")
        |> List.first()
        |> String.trim()

      real_ip ->
        String.trim(real_ip)

      true ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end
end
