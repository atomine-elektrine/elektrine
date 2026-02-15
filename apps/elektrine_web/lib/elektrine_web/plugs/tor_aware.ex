defmodule ElektrineWeb.Plugs.TorAware do
  @moduledoc """
  Plug to detect and handle connections via Tor onion service.

  When users connect via .onion address:
  - Sets :via_tor assign to true
  - Marks connection to skip IP logging
  - Enables privacy-preserving behavior
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    is_onion = String.ends_with?(conn.host || "", ".onion")

    conn
    |> assign(:via_tor, is_onion)
    |> put_private(:skip_ip_log, is_onion)
  end
end
