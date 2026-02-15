defmodule ElektrineWeb.Plugs.FlyRedirect do
  @moduledoc """
  Redirects all requests from *.fly.dev domains to elektrine.com.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if String.ends_with?(conn.host, ".fly.dev") do
      # Preserve the path and query string
      destination =
        case conn.query_string do
          "" -> "https://elektrine.com#{conn.request_path}"
          qs -> "https://elektrine.com#{conn.request_path}?#{qs}"
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
