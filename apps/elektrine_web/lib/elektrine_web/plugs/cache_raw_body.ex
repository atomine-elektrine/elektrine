defmodule ElektrineWeb.Plugs.CacheRawBody do
  @moduledoc """
  Caches the raw request body for webhook signature verification.

  This plug must be placed BEFORE Plug.Parsers in the endpoint pipeline.
  It reads and caches the raw body only for specified paths, then assigns
  a custom body_reader function that returns the cached body.
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    paths = Keyword.get(opts, :paths, [])
    %{paths: paths}
  end

  @impl true
  def call(%Plug.Conn{request_path: request_path} = conn, %{paths: paths}) do
    if request_path in paths do
      cache_raw_body(conn)
    else
      conn
    end
  end

  defp cache_raw_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} ->
        conn
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_private(:cached_body, body)

      {:more, _body, conn} ->
        # Body too large, don't cache
        conn

      {:error, _reason} ->
        conn
    end
  end
end
