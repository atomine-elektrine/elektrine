defmodule ElektrineWeb.Plugs.CSRFErrorHandler do
  @moduledoc """
  Custom CSRF error handler to provide better user experience when CSRF tokens are invalid.
  """

  import Plug.Conn
  import Phoenix.Controller
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, &handle_csrf_error/1)
  end

  defp handle_csrf_error(conn) do
    case conn.status do
      403 ->
        case get_resp_header(conn, "x-csrf-error") do
          ["true"] ->
            Logger.warning(
              "CSRF token error for #{conn.request_path} from IP #{get_client_ip(conn)}"
            )

            handle_csrf_response(conn)

          _ ->
            conn
        end

      _ ->
        conn
    end
  end

  defp handle_csrf_response(conn) do
    case get_format(conn) do
      "html" ->
        # Redirect to a safe path to avoid potential open redirect issues
        # Use referer if same-origin, otherwise default to homepage
        safe_path = get_safe_redirect_path(conn)

        conn
        |> put_flash(:error, "Your session has expired. Please try again.")
        |> redirect(to: safe_path)
        |> halt()

      "json" ->
        conn
        |> put_status(403)
        |> json(%{error: "Invalid CSRF token", message: "Please refresh the page and try again"})
        |> halt()

      _ ->
        conn
    end
  end

  # Validate the request path is a safe local path
  defp get_safe_redirect_path(conn) do
    path = conn.request_path

    cond do
      # Must be a local path (starts with /)
      not String.starts_with?(path, "/") ->
        "/"

      # Reject paths with protocol handlers that could cause issues
      String.contains?(path, "://") ->
        "/"

      # Reject double slashes that could be interpreted as protocol-relative URLs
      String.starts_with?(path, "//") ->
        "/"

      # Path seems safe, use it
      true ->
        path
    end
  end

  defp get_client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded_ips] ->
        forwarded_ips
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        case conn.remote_ip do
          {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
          {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
          ip -> to_string(ip)
        end
    end
  end
end
