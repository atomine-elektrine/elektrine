defmodule ElektrineWeb.Plugs.WebDAVMethodOverride do
  @moduledoc """
  Plug to handle WebDAV/CalDAV/CardDAV HTTP methods.

  Phoenix router doesn't natively support all WebDAV methods. This plug:
  1. Allows these methods to pass through Plug.Router
  2. Stores the original method in conn.assigns for route matching

  WebDAV methods supported:
  - PROPFIND - Get properties of resources
  - PROPPATCH - Set/remove properties
  - MKCOL - Create collection (folder/addressbook)
  - MKCALENDAR - Create calendar (CalDAV extension)
  - REPORT - Query/search resources
  - COPY - Copy resources
  - MOVE - Move resources
  - LOCK - Lock resources
  - UNLOCK - Unlock resources
  """

  @behaviour Plug

  @webdav_methods ~w(PROPFIND PROPPATCH MKCOL MKCALENDAR REPORT COPY MOVE LOCK UNLOCK)

  def init(opts), do: opts

  def call(conn, _opts) do
    method = conn.method

    if method in @webdav_methods do
      # Store original method and normalize to match route
      conn
      |> Plug.Conn.assign(:webdav_method, method)
      |> normalize_method(method)
    else
      conn
    end
  end

  # For Phoenix routing, we use `match` with custom methods
  # The method stays as-is, but we ensure it can pass through
  defp normalize_method(conn, _method) do
    # Phoenix 1.7+ supports custom HTTP methods via `match`
    # We just need to ensure the method is preserved
    conn
  end
end
