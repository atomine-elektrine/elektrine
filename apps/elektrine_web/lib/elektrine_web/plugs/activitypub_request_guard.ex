defmodule ElektrineWeb.Plugs.ActivityPubRequestGuard do
  @moduledoc """
  Rejects obviously abusive inbox requests before body caching and parsing.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @max_inbox_body_bytes 1 * 1024 * 1024

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", request_path: request_path} = conn, _opts) do
    if String.ends_with?(request_path, "/inbox") do
      conn
      |> put_private(:raw_body_max_length, @max_inbox_body_bytes)
      |> reject_oversized_inbox()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp reject_oversized_inbox(conn) do
    case Plug.Conn.get_req_header(conn, "content-length") do
      [value | _] ->
        case Integer.parse(value) do
          {length, ""} when length > @max_inbox_body_bytes ->
            conn
            |> put_status(:payload_too_large)
            |> json(%{error: "Inbox request body too large"})
            |> halt()

          _ ->
            conn
        end

      _ ->
        conn
    end
  end
end
