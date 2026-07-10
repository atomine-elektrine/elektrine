defmodule ElektrineWeb.API.KairoController do
  use ElektrineWeb, :controller

  alias ElektrineWeb.API.Response

  @default_source_limit 50
  @max_source_limit 1_000

  action_fallback ElektrineWeb.FallbackController

  def projects(conn, _params) do
    projects = Kairo.list_projects(conn.assigns.current_user)
    Response.ok(conn, %{projects: Enum.map(projects, &project_json/1)})
  end

  def create_project(conn, params) do
    attrs = Map.get(params, "project", params)

    case Kairo.create_project(conn.assigns.current_user, attrs) do
      {:ok, project} ->
        Response.created(conn, %{project: project_json(project)})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_project(conn, %{"id" => id} = params) do
    attrs = Map.get(params, "project", Map.delete(params, "id"))

    case Kairo.update_project(conn.assigns.current_user, id, attrs) do
      {:ok, project} -> Response.ok(conn, %{project: project_json(project)})
      {:error, :not_found} -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def delete_project(conn, %{"id" => id}) do
    case Kairo.delete_project(conn.assigns.current_user, id) do
      {:ok, project} -> Response.ok(conn, %{project: project_json(project), deleted: true})
      {:error, :not_found} -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def sources(conn, params) do
    case source_filters(params) do
      {:ok, filters} ->
        sources = Kairo.list_sources(conn.assigns.current_user, filters)
        total = Kairo.count_sources(conn.assigns.current_user, filters)
        limit = filters[:limit]
        offset = filters[:offset]

        Response.ok(conn, %{
          sources: Enum.map(sources, &source_json(&1, false)),
          pagination: %{
            limit: limit,
            offset: offset,
            total: total,
            has_more: offset + length(sources) < total
          }
        })

      {:error, :invalid_project_id} ->
        Response.error(conn, :bad_request, "invalid_project_id", "Project id is invalid")
    end
  end

  def source(conn, %{"id" => id}) do
    case Kairo.get_source(conn.assigns.current_user, id) do
      nil -> {:error, :not_found}
      source -> Response.ok(conn, %{source: source_json(source, true)})
    end
  end

  def create_source(conn, params) do
    attrs = Map.get(params, "source", params)
    upload = attrs["file"] || attrs["upload"]

    result =
      case upload do
        %Plug.Upload{} ->
          attrs = Map.drop(attrs, ["file", "upload"])
          Kairo.create_upload_source(conn.assigns.current_user, upload, attrs)

        _ ->
          Kairo.create_source(conn.assigns.current_user, attrs)
      end

    case result do
      {:ok, source} ->
        Response.created(conn, %{source: source_json(source, true)})

      {:error, :project_not_found} ->
        Response.error(conn, :not_found, "project_not_found", "Kairo project not found")

      {:error, :invalid_project_id} ->
        Response.error(conn, :bad_request, "invalid_project_id", "Project id is invalid")

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, reason} when is_struct(upload, Plug.Upload) ->
        upload_error(conn, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_source(conn, %{"id" => id} = params) do
    attrs = Map.get(params, "source", Map.delete(params, "id"))

    case Kairo.update_source(conn.assigns.current_user, id, attrs) do
      {:ok, source} ->
        Response.ok(conn, %{source: source_json(source, true)})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :project_not_found} ->
        Response.error(conn, :not_found, "project_not_found", "Kairo project not found")

      {:error, :invalid_project_id} ->
        Response.error(conn, :bad_request, "invalid_project_id", "Project id is invalid")

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def retry_source(conn, %{"id" => id}) do
    case Kairo.retry_url_source(conn.assigns.current_user, id) do
      {:ok, source} ->
        Response.accepted(conn, %{source: source_json(source, true), retry_queued: true})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :not_retryable} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "source_not_retryable",
          "Only failed URL sources without content can be retried"
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  def delete_source(conn, %{"id" => id}) do
    case Kairo.delete_source(conn.assigns.current_user, id) do
      {:ok, source} -> Response.ok(conn, %{source: source_json(source, false), deleted: true})
      {:error, :not_found} -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp source_filters(params) do
    with {:ok, project_id} <- parse_optional_id(Map.get(params, "project_id")) do
      filters =
        []
        |> Keyword.put(:limit, parse_limit(Map.get(params, "limit")))
        |> Keyword.put(:offset, parse_offset(Map.get(params, "offset")))
        |> maybe_put_filter(:status, Map.get(params, "status"))
        |> maybe_put_filter(:source_type, Map.get(params, "source_type"))
        |> maybe_put_filter(:project_id, project_id)

      {:ok, filters}
    end
  end

  defp maybe_put_filter(filters, _key, nil), do: filters
  defp maybe_put_filter(filters, _key, ""), do: filters
  defp maybe_put_filter(filters, key, value), do: Keyword.put(filters, key, value)

  defp parse_optional_id(nil), do: {:ok, nil}
  defp parse_optional_id(""), do: {:ok, nil}
  defp parse_optional_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_optional_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, :invalid_project_id}
    end
  end

  defp parse_optional_id(_value), do: {:error, :invalid_project_id}

  defp parse_limit(value) when is_integer(value),
    do: value |> max(1) |> min(@max_source_limit)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> parse_limit(limit)
      _other -> @default_source_limit
    end
  end

  defp parse_limit(_value), do: @default_source_limit

  defp parse_offset(value) when is_integer(value) and value > 0, do: value

  defp parse_offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} -> parse_offset(offset)
      _other -> 0
    end
  end

  defp parse_offset(_value), do: 0

  defp project_json(project) do
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

  defp source_json(source, include_content?) do
    %{
      id: source.id,
      project_id: source.project_id,
      project: loaded_project_json(source.project),
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

  defp loaded_project_json(%Kairo.Project{} = project), do: project_json(project)
  defp loaded_project_json(_project), do: nil

  defp maybe_put_content(payload, source, true) do
    Map.merge(payload, %{
      content: source.content,
      encrypted_content: source.encrypted_content
    })
  end

  defp maybe_put_content(payload, _source, false), do: payload

  defp upload_error(conn, {:file_too_large, message}) do
    Response.error(conn, :payload_too_large, "file_too_large", message)
  end

  defp upload_error(conn, :storage_limit_exceeded) do
    Response.error(
      conn,
      :unprocessable_entity,
      "storage_limit_exceeded",
      "Storage limit exceeded"
    )
  end

  defp upload_error(conn, {code, message})
       when code in [
              :empty_file,
              :invalid_file_type,
              :invalid_extension,
              :invalid_file_format,
              :malicious_content
            ] do
    Response.error(conn, :unprocessable_entity, to_string(code), message)
  end

  defp upload_error(conn, reason) when reason in [:image_dimensions_exceeded, :invalid_image] do
    Response.error(
      conn,
      :unprocessable_entity,
      to_string(reason),
      "The uploaded image could not be accepted"
    )
  end

  defp upload_error(conn, _reason) do
    Response.error(
      conn,
      :service_unavailable,
      "upload_failed",
      "The file could not be stored"
    )
  end
end
