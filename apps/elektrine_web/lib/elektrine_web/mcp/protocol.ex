defmodule ElektrineWeb.MCP.Protocol do
  @moduledoc """
  Minimal MCP JSON-RPC protocol adapter for the authenticated external API.
  """

  require Logger

  alias ElektrineWeb.MCP.ToolRegistry

  @protocol_version "2025-11-25"
  @supported_protocol_versions ~w(2025-11-25 2025-06-18 2025-03-26)
  @server_name "elektrine"
  @server_version "ext-v1"

  def handle(_conn, messages) when is_list(messages) do
    {:error, :bad_request,
     error_response(nil, -32_600, "Invalid Request", %{
       "reason" => "MCP Streamable HTTP accepts one JSON-RPC message per POST."
     })}
  end

  def handle(conn, message) when is_map(message), do: handle_message(conn, message)

  def handle(_conn, _message),
    do: {:error, :bad_request, error_response(nil, -32_600, "Invalid Request")}

  defp handle_message(conn, %{"jsonrpc" => "2.0", "method" => method} = message)
       when is_binary(method) do
    id = Map.get(message, "id")
    params = normalize_params(Map.get(message, "params", %{}))

    if is_nil(id) do
      dispatch_notification(conn, method, params)
    else
      dispatch_request(conn, method, params, id)
    end
  rescue
    error ->
      stacktrace = __STACKTRACE__

      Logger.error("""
      MCP request failed: #{Exception.message(error)}
      #{Exception.format_stacktrace(stacktrace)}
      """)

      {:reply, error_response(Map.get(message, "id"), -32_603, "Internal error")}
  end

  defp handle_message(_conn, %{"jsonrpc" => "2.0"} = message)
       when is_map_key(message, "result") or is_map_key(message, "error"),
       do: :accepted

  defp handle_message(_conn, message) when is_map(message) do
    {:error, :bad_request, error_response(Map.get(message, "id"), -32_600, "Invalid Request")}
  end

  defp dispatch_request(conn, method, params, id) do
    case dispatch(conn, method, params) do
      {:ok, result} -> {:reply, response(id, result)}
      {:error, code, message, data} -> {:reply, error_response(id, code, message, data)}
    end
  end

  defp dispatch_notification(conn, method, params) do
    case dispatch(conn, method, params) do
      {:notification, :ok} -> :accepted
      {:ok, _result} -> :accepted
      {:error, _code, _message, _data} -> :accepted
    end
  end

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(nil), do: %{}
  defp normalize_params(params), do: params

  defp dispatch(_conn, "initialize", params) do
    requested_version = if is_map(params), do: params["protocolVersion"], else: nil
    protocol_version = negotiated_protocol_version(requested_version)

    {:ok,
     %{
       "protocolVersion" => protocol_version,
       "capabilities" => %{
         "tools" => %{"listChanged" => false}
       },
       "serverInfo" => %{
         "name" => @server_name,
         "title" => "Elektrine",
         "version" => @server_version,
         "description" => "Elektrine external tool server"
       },
       "instructions" =>
         "Tools are scoped to the bearer token. Only invoke write tools after user approval."
     }}
  end

  defp dispatch(_conn, "notifications/initialized", _params), do: {:notification, :ok}

  defp dispatch(_conn, "ping", _params), do: {:ok, %{}}

  defp dispatch(conn, "tools/list", _params) do
    {:ok, %{"tools" => ToolRegistry.available_tools(conn)}}
  end

  defp dispatch(conn, "tools/call", %{"name" => name} = params) when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    case ToolRegistry.call(conn, name, arguments) do
      {:ok, result} ->
        {:ok, tool_result(result)}

      {:error, :unknown_tool} ->
        {:error, -32_602, "Unknown tool", %{"name" => name}}

      {:error, :insufficient_scope, required_scopes} ->
        {:ok,
         %{
           "isError" => true,
           "content" => [
             %{
               "type" => "text",
               "text" => "Token is missing required scope: #{Enum.join(required_scopes, ", ")}"
             }
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           "isError" => true,
           "content" => [
             %{"type" => "text", "text" => inspect(reason)}
           ]
         }}
    end
  end

  defp dispatch(_conn, "tools/call", _params) do
    {:error, -32_602, "Invalid params", %{"required" => ["name"]}}
  end

  defp dispatch(_conn, method, _params),
    do: {:error, -32_601, "Method not found", %{"method" => method}}

  defp negotiated_protocol_version(requested_version)
       when requested_version in @supported_protocol_versions,
       do: requested_version

  defp negotiated_protocol_version(_requested_version), do: @protocol_version

  defp tool_result(result) do
    %{
      "isError" => false,
      "content" => [
        %{
          "type" => "text",
          "text" => Jason.encode!(result, pretty: true)
        }
      ],
      "structuredContent" => result
    }
  end

  defp response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end
end
