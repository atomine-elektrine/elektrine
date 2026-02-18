defmodule ElektrineChatWeb.Plugs.APIRateLimit do
  @moduledoc """
  Plug for applying rate limiting to API endpoints.
  Uses IP address or user ID as the rate limit key.

  Adds standard rate limit headers to all responses:
  - `X-RateLimit-Limit` - Maximum requests allowed per minute
  - `X-RateLimit-Remaining` - Requests remaining in current window
  - `X-RateLimit-Reset` - Unix timestamp when the rate limit resets
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Elektrine.API.RateLimiter
  alias ElektrineChatWeb.ClientIP

  # Default limit per minute
  @default_limit 60

  def init(opts), do: opts

  def call(conn, _opts) do
    identifier = get_identifier(conn)

    case RateLimiter.check_rate_limit(identifier) do
      {:ok, :allowed} ->
        RateLimiter.record_attempt(identifier)

        # Add rate limit headers
        conn
        |> add_rate_limit_headers(identifier)

      {:error, {:rate_limited, retry_after, _reason}} ->
        now = System.system_time(:second)

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_header("x-ratelimit-limit", to_string(@default_limit))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_header("x-ratelimit-reset", to_string(now + retry_after))
        |> put_status(:too_many_requests)
        |> put_view(json: ElektrineChatWeb.ErrorJSON)
        |> render(:"429")
        |> halt()
    end
  end

  defp add_rate_limit_headers(conn, identifier) do
    status = RateLimiter.get_status(identifier)
    now = System.system_time(:second)

    # Get the minute window info (primary limit shown to users)
    {limit, remaining, reset} =
      case Map.get(status.attempts, 60) do
        %{limit: l, remaining: r} ->
          {l, r, now + 60}

        _ ->
          # Fallback if minute window not found
          {@default_limit, @default_limit, now + 60}
      end

    conn
    |> put_resp_header("x-ratelimit-limit", to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
    |> put_resp_header("x-ratelimit-reset", to_string(reset))
  end

  # Use user_id if authenticated, otherwise fall back to IP
  defp get_identifier(conn) do
    case conn.assigns[:current_user] do
      %{id: user_id} -> "user:#{user_id}"
      _ -> "ip:#{get_client_ip(conn)}"
    end
  end

  defp get_client_ip(conn) do
    ClientIP.client_ip(conn)
  end
end
