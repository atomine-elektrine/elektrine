defmodule ElektrineWeb.Plugs.FlyRedirect do
  @moduledoc """
  Optionally redirects all requests from `*.fly.dev` domains to a configured host.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    redirect_host = Application.get_env(:elektrine, :fly_redirect_host)

    if is_binary(redirect_host) and redirect_host != "" and
         String.ends_with?(conn.host, ".fly.dev") do
      # Preserve the path and query string
      destination =
        case conn.query_string do
          "" -> "https://#{redirect_host}#{conn.request_path}"
          qs -> "https://#{redirect_host}#{conn.request_path}?#{qs}"
        end

      conn
      |> put_resp_header("location", destination)
      |> send_resp(301, "Moved Permanently")
      |> halt()
    else
      conn
    end
  end
end
