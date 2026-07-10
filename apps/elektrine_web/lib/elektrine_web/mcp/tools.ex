defmodule ElektrineWeb.MCP.Tools do
  @moduledoc """
  MCP tool handlers backed by existing Elektrine contexts.
  """

  alias Elektrine.Nerve
  alias Elektrine.Nerve.Payloads
  alias Elektrine.Search
  alias ElektrineWeb.MCP.ToolRegistry

  @default_limit 25
  @max_limit 100
  @email_mcp_tools :"Elixir.ElektrineEmail.MCPTools"

  def capabilities(conn, _arguments) do
    {:ok,
     %{
       authenticated_user: account_payload(conn.assigns.current_user),
       token: token_payload(conn),
       tools: ToolRegistry.available_tools(conn)
     }}
  end

  def account_me(conn, _arguments) do
    {:ok, %{user: account_payload(conn.assigns.current_user), token: token_payload(conn)}}
  end

  def search(conn, %{"query" => query} = arguments) when is_binary(query) do
    limit =
      arguments
      |> Map.get("limit", @default_limit)
      |> parse_positive_int(@default_limit)
      |> min(@max_limit)

    result =
      Search.global_search(conn.assigns.current_user, query,
        limit: limit,
        scopes: ToolRegistry.token_scopes(conn),
        enforce_scopes: true
      )

    {:ok, %{query: query, total_count: result.total_count, results: result.results}}
  end

  def search(_conn, _arguments), do: {:error, :missing_query}

  def actions_list(conn, _arguments) do
    actions =
      Search.list_actions(
        current_user: conn.assigns.current_user,
        scopes: ToolRegistry.token_scopes(conn),
        enforce_scopes: true
      )

    {:ok, %{actions: Enum.map(actions, &action_payload/1)}}
  end

  def actions_execute(conn, %{"command" => command}) when is_binary(command) do
    case Search.execute_action(conn.assigns.current_user, command,
           scopes: ToolRegistry.token_scopes(conn),
           enforce_scopes: true,
           source: "mcp"
         ) do
      {:ok, result} -> {:ok, %{result: normalize_action_result(result)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def actions_execute(_conn, _arguments), do: {:error, :missing_command}

  def email_messages_list(conn, arguments), do: call_email_tool(:messages_list, conn, arguments)

  def email_messages_search(conn, arguments),
    do: call_email_tool(:messages_search, conn, arguments)

  def email_messages_get(conn, arguments), do: call_email_tool(:messages_get, conn, arguments)

  def email_messages_send(conn, arguments), do: call_email_tool(:messages_send, conn, arguments)

  def email_messages_update(conn, arguments),
    do: call_email_tool(:messages_update, conn, arguments)

  def kairo_projects_list(conn, arguments) do
    opts =
      []
      |> maybe_put(:status, string_value(arguments["status"]))

    projects =
      conn.assigns.current_user
      |> Kairo.list_projects(opts)
      |> Enum.map(&project_payload/1)

    {:ok, %{projects: projects}}
  end

  def kairo_sources_list(conn, arguments) do
    with {:ok, project_id} <- parse_optional_id(arguments["project_id"]) do
      opts =
        []
        |> maybe_put(
          :limit,
          parse_positive_int(arguments["limit"], @default_limit) |> min(@max_limit)
        )
        |> maybe_put(:offset, parse_non_negative_int(arguments["offset"], 0))
        |> maybe_put(:status, string_value(arguments["status"]))
        |> maybe_put(:source_type, string_value(arguments["source_type"]))
        |> maybe_put(:project_id, project_id)

      sources = Kairo.list_sources(conn.assigns.current_user, opts)
      total = Kairo.count_sources(conn.assigns.current_user, opts)

      {:ok,
       %{
         sources: Enum.map(sources, &source_payload(&1, false)),
         pagination: %{
           limit: opts[:limit],
           offset: opts[:offset],
           total: total,
           has_more: opts[:offset] + length(sources) < total
         }
       }}
    end
  end

  def kairo_sources_get(conn, %{"id" => id}) do
    case Kairo.get_source(conn.assigns.current_user, id) do
      nil -> {:error, :not_found}
      source -> {:ok, %{source: source_payload(source, true)}}
    end
  end

  def kairo_sources_get(_conn, _arguments), do: {:error, :missing_id}

  def kairo_sources_create(conn, arguments) do
    case Kairo.create_source(conn.assigns.current_user, arguments) do
      {:ok, source} -> {:ok, %{source: source_payload(source, true)}}
      {:error, :project_not_found} -> {:error, :project_not_found}
      {:error, :invalid_project_id} -> {:error, :invalid_project_id}
      {:error, changeset} -> {:error, %{validation_errors: errors_on(changeset)}}
    end
  end

  def kairo_sources_retry(conn, %{"id" => id}) do
    case Kairo.retry_url_source(conn.assigns.current_user, id) do
      {:ok, source} -> {:ok, %{source: source_payload(source, true), retry_queued: true}}
      {:error, reason} when reason in [:not_found, :not_retryable] -> {:error, reason}
      {:error, changeset} -> {:error, %{validation_errors: errors_on(changeset)}}
    end
  end

  def kairo_sources_retry(_conn, _arguments), do: {:error, :missing_id}

  def nerve_entries_list(conn, _arguments) do
    entries =
      conn.assigns.current_user.id
      |> Nerve.list_entries()
      |> Enum.map(&nerve_entry_payload(&1, false))

    {:ok, %{entries: entries}}
  end

  def nerve_entries_get(conn, %{"id" => id}) do
    with {:ok, entry_id} <- parse_id(id),
         {:ok, entry} <- Nerve.get_entry_ciphertext(conn.assigns.current_user.id, entry_id) do
      {:ok, %{entry: nerve_entry_payload(entry, true)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def nerve_entries_get(_conn, _arguments), do: {:error, :missing_id}

  def nerve_entries_create(conn, arguments) do
    with {:ok, attrs} <- Payloads.decode_encrypted_entry_params(arguments),
         {:ok, entry} <- Nerve.create_entry(conn.assigns.current_user.id, attrs) do
      {:ok, %{entry: nerve_entry_payload(entry, true)}}
    else
      {:error, :invalid_payload} -> {:error, :invalid_payload}
      {:error, changeset} -> {:error, %{validation_errors: errors_on(changeset)}}
    end
  end

  defp account_payload(user) do
    %{
      id: user.id,
      username: user.username,
      handle: user.handle,
      display_name: user.display_name
    }
  end

  defp token_payload(conn) do
    token = conn.assigns[:api_token]

    %{
      id: token && Map.get(token, :id),
      name: token && Map.get(token, :name),
      token_prefix: token && Map.get(token, :token_prefix),
      scopes: ToolRegistry.token_scopes(conn),
      expires_at: token && Map.get(token, :expires_at),
      last_used_at: token && Map.get(token, :last_used_at)
    }
  end

  defp action_payload(action) do
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

  defp normalize_action_result(result) do
    Map.update(result, :mode, nil, fn
      mode when is_atom(mode) -> to_string(mode)
      mode -> mode
    end)
  end

  defp call_email_tool(function, conn, arguments) do
    user = conn.assigns.current_user

    if Code.ensure_loaded?(@email_mcp_tools) and function_exported?(@email_mcp_tools, function, 2) do
      apply(@email_mcp_tools, function, [user, arguments])
    else
      {:error, :email_unavailable}
    end
  end

  defp project_payload(project) do
    %{
      id: project.id,
      name: project.name,
      slug: project.slug,
      description: project.description,
      status: project.status,
      autonomy_level: project.autonomy_level,
      inserted_at: project.inserted_at,
      updated_at: project.updated_at
    }
  end

  defp source_payload(source, include_content?) do
    %{
      id: source.id,
      project_id: source.project_id,
      project: loaded_project_payload(source.project),
      source_type: source.source_type,
      title: source.title,
      url: source.url,
      content_format: source.content_format,
      status: source.status,
      error_message: source.error_message,
      encrypted: source.encrypted == true,
      tags: source.tags || [],
      metadata: source.metadata || %{},
      raw_hash: source.raw_hash,
      ingested_at: source.ingested_at,
      processed_at: source.processed_at,
      inserted_at: source.inserted_at,
      updated_at: source.updated_at
    }
    |> maybe_put_content(source, include_content?)
  end

  defp loaded_project_payload(%Kairo.Project{} = project), do: project_payload(project)
  defp loaded_project_payload(_project), do: nil

  defp maybe_put_content(payload, source, true) do
    Map.merge(payload, %{
      content: source.content,
      encrypted_content: source.encrypted_content
    })
  end

  defp maybe_put_content(payload, _source, false), do: payload

  defp nerve_entry_payload(entry, include_ciphertext?) do
    %{
      id: entry.id,
      title: entry.title,
      login_username: entry.login_username,
      website: entry.website,
      encrypted_metadata: entry.encrypted_metadata,
      encrypted_password:
        if(include_ciphertext?, do: Map.get(entry, :encrypted_password), else: nil),
      encrypted_notes: if(include_ciphertext?, do: Map.get(entry, :encrypted_notes), else: nil),
      inserted_at: entry.inserted_at,
      updated_at: Map.get(entry, :updated_at)
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp string_value(value) when is_binary(value) and value != "", do: value
  defp string_value(_value), do: nil

  defp parse_optional_id(nil), do: {:ok, nil}
  defp parse_optional_id(""), do: {:ok, nil}
  defp parse_optional_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_optional_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_project_id}
    end
  end

  defp parse_optional_id(_value), do: {:error, :invalid_project_id}

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :bad_request}
    end
  end

  defp parse_id(_value), do: {:error, :bad_request}

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_value, default), do: default

  defp parse_non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_non_negative_int(_value, default), do: default

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
