defmodule ElektrineWeb.API.KairoController do
  use ElektrineWeb, :controller

  alias ElektrineWeb.API.Response

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

  def sources(conn, params) do
    sources =
      conn.assigns.current_user
      |> Kairo.list_sources(source_filters(params))

    Response.ok(conn, %{sources: Enum.map(sources, &source_json(&1, false))})
  end

  def source(conn, %{"id" => id}) do
    case Kairo.get_source(conn.assigns.current_user, id) do
      nil -> {:error, :not_found}
      source -> Response.ok(conn, %{source: source_json(source, true)})
    end
  end

  def create_source(conn, params) do
    attrs = Map.get(params, "source", params)

    case Kairo.create_source(conn.assigns.current_user, attrs) do
      {:ok, source} ->
        Response.created(conn, %{source: source_json(source, true)})

      {:error, :project_not_found} ->
        Response.error(conn, :not_found, "project_not_found", "Kairo project not found")

      {:error, :invalid_project_id} ->
        Response.error(conn, :bad_request, "invalid_project_id", "Project id is invalid")

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp source_filters(params) do
    []
    |> maybe_put_filter(:limit, Map.get(params, "limit"))
    |> maybe_put_filter(:status, Map.get(params, "status"))
    |> maybe_put_filter(:source_type, Map.get(params, "source_type"))
    |> maybe_put_filter(:project_id, parse_optional_id(Map.get(params, "project_id")))
  end

  defp maybe_put_filter(filters, _key, nil), do: filters
  defp maybe_put_filter(filters, _key, ""), do: filters
  defp maybe_put_filter(filters, key, value), do: Keyword.put(filters, key, value)

  defp parse_optional_id(nil), do: nil
  defp parse_optional_id(""), do: nil
  defp parse_optional_id(value) when is_integer(value), do: value

  defp parse_optional_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _other -> nil
    end
  end

  defp parse_optional_id(_value), do: nil

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
      tags: source.tags || [],
      metadata: source.metadata || %{},
      raw_hash: source.raw_hash,
      ingested_at: source.ingested_at,
      processed_at: source.processed_at,
      inserted_at: source.inserted_at,
      updated_at: source.updated_at
    }
    |> maybe_put_content(source.content, include_content?)
  end

  defp loaded_project_json(%Kairo.Project{} = project), do: project_json(project)
  defp loaded_project_json(_project), do: nil

  defp maybe_put_content(payload, content, true), do: Map.put(payload, :content, content)
  defp maybe_put_content(payload, _content, false), do: payload
end
