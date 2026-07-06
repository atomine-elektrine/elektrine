defmodule ElektrineWeb.API.MCPController do
  @moduledoc """
  Authenticated MCP endpoint for PAT-backed tool clients.
  """
  use ElektrineWeb, :controller

  alias ElektrineWeb.MCP.Protocol
  @protocol_version "2025-11-25"
  @compatible_protocol_versions ~w(2025-11-25 2025-06-18 2025-03-26)

  def rpc(conn, %{"_json" => messages}) when is_list(messages) do
    rpc(conn, messages)
  end

  def rpc(conn, params) do
    with :ok <- validate_origin_header(conn),
         :ok <- validate_accept_header(conn),
         :ok <- validate_protocol_version_header(conn) do
      case Protocol.handle(conn, params) do
        :accepted ->
          send_resp(conn, :accepted, "")

        {:reply, response} ->
          conn
          |> put_resp_header("mcp-protocol-version", @protocol_version)
          |> json(response)

        {:error, status, response} ->
          conn
          |> put_status(status)
          |> json(response)
      end
    else
      {:error, status, response} ->
        conn
        |> put_status(status)
        |> json(response)
    end
  end

  def event_stream(conn, _params) do
    with :ok <- validate_origin_header(conn),
         :ok <- validate_protocol_version_header(conn) do
      conn
      |> put_resp_header("allow", "POST, GET")
      |> send_resp(:method_not_allowed, "")
    else
      {:error, status, response} ->
        conn
        |> put_status(status)
        |> json(response)
    end
  end

  def delete_session(conn, _params) do
    with :ok <- validate_origin_header(conn),
         :ok <- validate_protocol_version_header(conn) do
      conn
      |> put_resp_header("allow", "POST, GET")
      |> send_resp(:method_not_allowed, "")
    else
      {:error, status, response} ->
        conn
        |> put_status(status)
        |> json(response)
    end
  end

  defp validate_origin_header(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin | _rest] ->
        case URI.parse(origin) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and host == conn.host ->
            :ok

          _ ->
            {:error, :forbidden,
             json_rpc_error(nil, -32_600, "Invalid Request", %{
               "reason" => "Origin is not allowed for this MCP endpoint."
             })}
        end
    end
  end

  defp validate_accept_header(conn) do
    accepts =
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(&1 |> String.split(";") |> hd() |> String.trim() |> String.downcase()))

    cond do
      "application/json" in accepts and "text/event-stream" in accepts ->
        :ok

      "*/*" in accepts ->
        :ok

      true ->
        {:error, :not_acceptable,
         json_rpc_error(nil, -32_600, "Invalid Request", %{
           "reason" => "MCP requests must accept application/json and text/event-stream."
         })}
    end
  end

  defp validate_protocol_version_header(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [version | _rest] when version in @compatible_protocol_versions ->
        :ok

      [version | _rest] ->
        {:error, :bad_request,
         json_rpc_error(nil, -32_600, "Invalid Request", %{
           "reason" => "Unsupported MCP protocol version.",
           "protocolVersion" => version,
           "supportedProtocolVersions" => @compatible_protocol_versions
         })}
    end
  end

  defp json_rpc_error(id, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
  end
end
