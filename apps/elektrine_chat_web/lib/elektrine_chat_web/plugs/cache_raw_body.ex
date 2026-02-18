defmodule ElektrineChatWeb.Plugs.CacheRawBody do
  @moduledoc """
  Caches raw request bodies for selected signed endpoints.

  This plug must be placed BEFORE Plug.Parsers in the endpoint pipeline.
  It marks selected paths for raw body caching, and its `read_body/2` callback
  can be used as Plug.Parsers `:body_reader`.
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
      Plug.Conn.put_private(conn, :cache_raw_body, true)
    else
      conn
    end
  end

  @doc """
  Plug.Parsers-compatible body reader that optionally caches raw bodies.
  """
  def read_body(conn, opts) do
    if conn.private[:cache_raw_body] do
      case conn.private[:cached_body] do
        body when is_binary(body) ->
          {:ok, body, conn}

        _ ->
          read_and_cache_full_body(conn, opts, "")
      end
    else
      Plug.Conn.read_body(conn, opts)
    end
  end

  defp read_and_cache_full_body(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        body = acc <> chunk

        conn =
          conn |> Plug.Conn.assign(:raw_body, body) |> Plug.Conn.put_private(:cached_body, body)

        {:ok, body, conn}

      {:more, chunk, conn} ->
        read_and_cache_full_body(conn, opts, acc <> chunk)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
