defmodule ElektrineWeb.API.GlobalSearchController do
  @moduledoc """
  External API controller for global search and command actions.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Search
  alias ElektrineWeb.ClientIP

  @default_limit 50
  @max_limit 100

  @doc """
  GET /api/ext/search?q=...
  """
  def index(conn, %{"q" => query} = params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_limit) |> min(@max_limit)
    result = Search.global_search(user, query, limit: limit)

    conn
    |> put_status(:ok)
    |> json(%{
      query: query,
      total_count: result.total_count,
      results: result.results
    })
  end

  def index(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameter: q"})
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

    conn
    |> put_status(:ok)
    |> json(%{
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
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing required parameter: command"})
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
          conn
          |> put_status(:ok)
          |> json(%{result: format_result(result)})

        {:error, :unknown_action} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Unknown action"})

        {:error, :insufficient_scope} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Token is missing required scope"})

        {:error, :unauthorized} ->
          conn
          |> put_status(:unauthorized)
          |> json(%{error: "Unauthorized"})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Action execution failed", reason: inspect(reason)})
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
