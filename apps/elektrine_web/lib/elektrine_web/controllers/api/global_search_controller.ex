defmodule ElektrineWeb.API.GlobalSearchController do
  @moduledoc """
  External API controller for global search and command actions.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Search
  alias ElektrineWeb.API.Response
  alias ElektrineWeb.ClientIP

  @default_limit 50
  @max_limit 100

  @doc """
  GET /api/ext/search?q=...
  """
  def index(conn, %{"q" => query} = params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_limit) |> min(@max_limit)

    result =
      Search.global_search(user, query,
        limit: limit,
        scopes: token_scopes(conn),
        enforce_scopes: true
      )

    Response.ok(
      conn,
      %{
        query: query,
        total_count: result.total_count,
        results: result.results
      },
      %{pagination: %{limit: limit}}
    )
  end

  def index(conn, _params) do
    Response.error(conn, :bad_request, "missing_parameter", "Missing required parameter: q")
  end

  @doc """
  GET /api/ext/search/actions
  """
  def actions(conn, _params) do
    actions =
      Search.list_actions(
        scopes: token_scopes(conn),
        enforce_scopes: true
      )

    Response.ok(conn, %{
      actions: Enum.map(actions, &format_action/1)
    })
  end

  @doc """
  POST /api/ext/search/actions/execute
  """
  def execute(conn, params) do
    user = conn.assigns.current_user
    command = params["command"] || params["action"] || params["id"]

    if is_nil(command) or String.trim(to_string(command)) == "" do
      Response.error(
        conn,
        :bad_request,
        "missing_parameter",
        "Missing required parameter: command"
      )
    else
      opts = [
        scopes: token_scopes(conn),
        enforce_scopes: true,
        source: "api",
        ip_address: ClientIP.client_ip(conn),
        user_agent: user_agent(conn)
      ]

      case Search.execute_action(user, command, opts) do
        {:ok, result} ->
          Response.ok(conn, %{result: format_result(result)})

        {:error, :unknown_action} ->
          Response.error(conn, :not_found, "unknown_action", "Unknown action")

        {:error, :insufficient_scope} ->
          Response.error(
            conn,
            :forbidden,
            "insufficient_scope",
            "Token is missing required scope"
          )

        {:error, :unauthorized} ->
          Response.error(conn, :unauthorized, "unauthorized", "Unauthorized")

        {:error, reason} ->
          Response.error(
            conn,
            :unprocessable_entity,
            "action_execution_failed",
            "Action execution failed",
            inspect(reason)
          )
      end
    end
  end

  defp token_scopes(conn) do
    case conn.assigns[:api_token] do
      %{scopes: scopes} when is_list(scopes) -> scopes
      _ -> []
    end
  end

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [value | _] -> value
      _ -> nil
    end
  end

  defp format_action(action) do
    %{
      id: action.id,
      title: action.title,
      command: action[:command],
      content: action.content,
      url: action.url,
      required_scopes: action[:required_scopes] || [],
      keywords: action[:keywords] || []
    }
  end

  defp format_result(result) do
    result
    |> Map.update(:mode, nil, fn
      mode when is_atom(mode) -> to_string(mode)
      mode -> mode
    end)
  end

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_, default), do: default
end
