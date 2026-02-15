defmodule ElektrineWeb.DAVController do
  @moduledoc """
  Controller for CalDAV/CardDAV discovery endpoints.

  Handles:
  - /.well-known/caldav - CalDAV service discovery
  - /.well-known/carddav - CardDAV service discovery
  - OPTIONS requests for DAV capabilities
  """

  use ElektrineWeb, :controller

  alias ElektrineWeb.DAV.ResponseHelpers

  @doc """
  CalDAV service discovery.
  Redirects to the principal URL for the authenticated user.
  """
  def caldav_discovery(conn, _params) do
    case conn.assigns[:current_user] do
      nil ->
        # Not authenticated - redirect to base calendars path
        base_url = base_url(conn)

        conn
        |> put_resp_header("location", "#{base_url}/calendars/")
        |> send_resp(301, "")

      user ->
        base_url = base_url(conn)

        conn
        |> put_resp_header("location", "#{base_url}/calendars/#{user.username}/")
        |> send_resp(301, "")
    end
  end

  @doc """
  CardDAV service discovery.
  Redirects to the principal URL for the authenticated user.
  """
  def carddav_discovery(conn, _params) do
    case conn.assigns[:current_user] do
      nil ->
        base_url = base_url(conn)

        conn
        |> put_resp_header("location", "#{base_url}/addressbooks/")
        |> send_resp(301, "")

      user ->
        base_url = base_url(conn)

        conn
        |> put_resp_header("location", "#{base_url}/addressbooks/#{user.username}/")
        |> send_resp(301, "")
    end
  end

  @doc """
  OPTIONS request for DAV capabilities.
  """
  def options(conn, _params) do
    conn
    |> ResponseHelpers.put_dav_headers()
    |> send_resp(200, "")
  end

  @doc """
  Root PROPFIND for current-user-principal discovery.
  Some clients PROPFIND the root to discover the principal.
  """
  def propfind_root(conn, _params) do
    case conn.assigns[:current_user] do
      nil ->
        ResponseHelpers.send_forbidden(conn)

      user ->
        base_url = base_url(conn)

        responses = [
          %{
            href: "#{base_url}/",
            propstat: [
              {200,
               [
                 {:resourcetype, :collection},
                 {:current_user_principal, "#{base_url}/principals/users/#{user.username}/"},
                 {:displayname, "Elektrine DAV"}
               ]}
            ]
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
