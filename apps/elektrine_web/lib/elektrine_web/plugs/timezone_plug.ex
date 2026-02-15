defmodule ElektrineWeb.Plugs.TimezonePlug do
  @moduledoc """
  Reads detected timezone from cookie and stores it in session.
  This allows server-side rendering to use the detected timezone immediately.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.cookies["detected_timezone"] do
      nil ->
        conn

      timezone when is_binary(timezone) ->
        # Store detected timezone in session for LiveView to access
        put_session(conn, "detected_timezone", timezone)
    end
  end
end
