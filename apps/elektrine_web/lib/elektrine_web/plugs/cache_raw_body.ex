defmodule ElektrineWeb.Plugs.CacheRawBody do
  @moduledoc """
  Caches raw request bodies for selected signed endpoints.

  This plug must be placed BEFORE Plug.Parsers in the endpoint pipeline.
  It marks selected paths for raw body caching, and its `read_body/2` callback
  can be used as Plug.Parsers `:body_reader`.
  """

  @behaviour Plug

  @default_max_length 1 * 1024 * 1024

  @impl true
  def init(opts) do
    paths = Keyword.get(opts, :paths, [])
    suffixes = Keyword.get(opts, :suffixes, [])
    max_length = Keyword.get(opts, :max_length, @default_max_length)
    max_lengths = Keyword.get(opts, :max_lengths, %{})
    %{paths: paths, suffixes: suffixes, max_length: max_length, max_lengths: max_lengths}
  end

  @impl true
  def call(
        %Plug.Conn{request_path: request_path} = conn,
        %{paths: paths, suffixes: suffixes, max_length: max_length, max_lengths: max_lengths}
      ) do
    if request_path in paths or Enum.any?(suffixes, &String.ends_with?(request_path, &1)) do
      conn
      |> Plug.Conn.put_private(:cache_raw_body, true)
      |> Plug.Conn.put_private(
        :raw_body_max_length,
        Map.get(max_lengths, request_path, max_length)
      )
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
    max_length = conn.private[:raw_body_max_length]
    opts = if is_integer(max_length), do: Keyword.put(opts, :length, max_length), else: opts

    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        with {:ok, body} <- append_chunk(acc, chunk, max_length) do
          conn =
            conn |> Plug.Conn.assign(:raw_body, body) |> Plug.Conn.put_private(:cached_body, body)

          {:ok, body, conn}
        end

      {:more, chunk, conn} ->
        with {:ok, body} <- append_chunk(acc, chunk, max_length) do
          read_and_cache_full_body(conn, opts, body)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_chunk(acc, chunk, max_length) when is_integer(max_length) do
    if byte_size(acc) + byte_size(chunk) > max_length do
      {:error, :too_large}
    else
      {:ok, acc <> chunk}
    end
  end

  defp append_chunk(acc, chunk, _max_length), do: {:ok, acc <> chunk}
end
