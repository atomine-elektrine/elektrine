defmodule ElektrineWeb.Plugs.ActivityPubAccept do
  @moduledoc """
  Custom plug for ActivityPub routes that accepts any content type.
  ActivityPub clients send various Accept headers, so we don't restrict.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    # Don't check Accept header - just let it through
    # Controllers will set appropriate response content types
    conn
  end
end
