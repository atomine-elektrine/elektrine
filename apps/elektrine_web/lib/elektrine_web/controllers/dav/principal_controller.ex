defmodule ElektrineWeb.DAV.PrincipalController do
  @moduledoc """
  WebDAV principal controller for user principal discovery.
  """

  use ElektrineWeb, :controller

  alias ElektrineWeb.DAV.{ResponseHelpers, Properties}

  @doc """
  PROPFIND on principal resource.
  """
  def propfind(conn, %{"username" => username}) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      base_url = base_url(conn)

      responses = [
        %{
          href: "#{base_url}/principals/users/#{username}/",
          propstat: [{200, Properties.principal_props(user, base_url)}]
        }
      ]

      ResponseHelpers.send_multistatus(conn, responses)
    end
  end

  defp base_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    port = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
    "#{scheme}://#{conn.host}#{port}"
  end
end
