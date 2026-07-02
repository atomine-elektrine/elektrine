defmodule ElektrineWeb.Plugs.APIRateLimit do
  @moduledoc """
  Plug for applying rate limiting to API endpoints.
  Uses IP address or user ID as the rate limit key.

  Adds standard rate limit headers to all responses:
  - `X-RateLimit-Limit` - Maximum requests allowed per minute
  - `X-RateLimit-Remaining` - Requests remaining in current window
  - `X-RateLimit-Reset` - Unix timestamp when the rate limit resets
  """
  import Plug.Conn

  alias Elektrine.API.RateLimiter
  alias ElektrineWeb.ClientIP

  # Default limit per minute
  @default_limit 60

  def init(opts), do: opts

  def call(conn, opts) do
    if test_env?() and not Keyword.get(opts, :enabled_in_test, false) do
      conn
    else
      do_call(conn, opts)
    end
  end

  defp do_call(conn, opts) do
    limiter = limiter(conn, opts)
    identifier = get_identifier(conn, opts)

    case limiter.check_rate_limit(identifier) do
      {:ok, :allowed} ->
        limiter.record_attempt(identifier)

        # Add rate limit headers
        conn
        |> add_rate_limit_headers(limiter, identifier)

      {:error, {:rate_limited, retry_after, _reason}} ->
        now = System.system_time(:second)

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_header("x-ratelimit-limit", to_string(minute_limit(limiter)))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_header("x-ratelimit-reset", to_string(now + retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{errors: %{detail: "Too Many Requests"}}))
        |> halt()
    end
  end

  defp test_env?, do: Application.get_env(:elektrine, :environment) == :test

  defp add_rate_limit_headers(conn, limiter, identifier) do
    status = limiter.get_status(identifier)
    now = System.system_time(:second)

    # Get the minute window info (primary limit shown to users)
    {limit, remaining, reset} =
      case Map.get(status.attempts, 60) do
        %{limit: l, remaining: r} ->
          {l, r, now + 60}

        _ ->
          # Fallback if minute window not found
          limit = minute_limit(limiter)
          {limit, limit, now + 60}
      end

    conn
    |> put_resp_header("x-ratelimit-limit", to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
    |> put_resp_header("x-ratelimit-reset", to_string(reset))
  end

  # Use user_id if authenticated, otherwise fall back to IP
  defp get_identifier(conn, opts) do
    identifier =
      if Keyword.get(opts, :ip_only, false) do
        "ip:#{get_client_ip(conn)}"
      else
        case conn.assigns do
          %{federation_peer_domain: domain} when is_binary(domain) ->
            "federation:#{String.downcase(domain)}"

          %{current_user: %{id: user_id}} ->
            "user:#{user_id}"

          _ ->
            "ip:#{get_client_ip(conn)}"
        end
      end

    case Keyword.get(opts, :key_prefix) do
      prefix when is_binary(prefix) and prefix != "" -> "#{prefix}:#{identifier}"
      _ -> identifier
    end
  end

  defp limiter(conn, opts) do
    case Keyword.get(opts, :limiter) do
      module when is_atom(module) and not is_nil(module) -> module
      _ -> scoped_limiter(conn)
    end
  end

  defp scoped_limiter(%{method: method, path_info: path}) do
    cond do
      import_path?(path) ->
        Elektrine.API.ImportRateLimiter

      media_path?(path) ->
        Elektrine.API.MediaRateLimiter

      search_path?(path) ->
        Elektrine.API.SearchRateLimiter

      api_path?(path) and write_method?(method) ->
        Elektrine.API.WriteRateLimiter

      timeline_path?(path) ->
        Elektrine.API.TimelineRateLimiter

      true ->
        RateLimiter
    end
  end

  defp search_path?(["api", version, "search"]) when version in ["v1", "v2"], do: true
  defp search_path?(["api", "v1", "accounts", "search"]), do: true
  defp search_path?(["api", "v1", "accounts", "lookup"]), do: true
  defp search_path?(_path), do: false

  defp timeline_path?(["api", "v1", "timelines" | _rest]), do: true
  defp timeline_path?(["api", "v1", "statuses" | _rest]), do: true
  defp timeline_path?(["api", "v1", "bookmarks"]), do: true
  defp timeline_path?(["api", "v1", "favourites"]), do: true
  defp timeline_path?(["api", "v1", "trends" | _rest]), do: true
  defp timeline_path?(_path), do: false

  defp media_path?(["api", version, "media" | _rest]) when version in ["v1", "v2"], do: true
  defp media_path?(_path), do: false

  defp import_path?(["api", "v1", "pleroma", "import"]), do: true

  defp import_path?(["api", "v1", "pleroma", import])
       when import in ["follow_import", "mutes_import", "blocks_import"], do: true

  defp import_path?(["api", "pleroma", import])
       when import in ["follow_import", "mutes_import", "blocks_import"], do: true

  defp import_path?(_path), do: false

  defp api_path?(["api" | _rest]), do: true
  defp api_path?(_path), do: false

  defp write_method?(method) when method in ["POST", "PUT", "PATCH", "DELETE"], do: true
  defp write_method?(_method), do: false

  defp minute_limit(limiter) do
    limiter.config()
    |> Map.get(:limits, [])
    |> Enum.find_value(@default_limit, fn
      {:minute, limit} -> limit
      {60, limit} -> limit
      _ -> nil
    end)
  rescue
    _ -> @default_limit
  end

  defp get_client_ip(conn) do
    ClientIP.client_ip(conn)
  end
end
