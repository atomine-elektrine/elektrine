defmodule Kairo do
  @moduledoc """
  Personal data OS module for ingesting source material into a durable,
  user-owned knowledge substrate.
  """

  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.Repo
  alias Kairo.{Project, Source}

  @default_source_limit 50
  @max_source_limit 200

  def list_projects(%User{id: user_id}), do: list_projects(user_id)

  def list_projects(user_id) do
    Project
    |> where([project], project.user_id == ^user_id)
    |> order_by([project], asc: project.name)
    |> Repo.all()
  end

  def get_project(%User{id: user_id}, id), do: get_project(user_id, id)

  def get_project(user_id, id) do
    case parse_id(id) do
      {:ok, project_id} ->
        Project
        |> where([project], project.user_id == ^user_id and project.id == ^project_id)
        |> Repo.one()

      :error ->
        nil
    end
  end

  def get_project_by_slug(%User{id: user_id}, slug), do: get_project_by_slug(user_id, slug)

  def get_project_by_slug(user_id, slug) when is_binary(slug) do
    Project
    |> where([project], project.user_id == ^user_id and project.slug == ^slug)
    |> Repo.one()
  end

  def get_project_by_slug(_user_id, _slug), do: nil

  def create_project(%User{id: user_id}, attrs), do: create_project(user_id, attrs)

  def create_project(user_id, attrs) do
    %Project{}
    |> Project.changeset(Map.put(normalize_attrs(attrs), "user_id", user_id))
    |> Repo.insert()
  end

  def list_sources(user_or_id, opts \\ [])

  def list_sources(%User{id: user_id}, opts), do: list_sources(user_id, opts)

  def list_sources(user_id, opts) do
    limit =
      opts
      |> Keyword.get(:limit, @default_source_limit)
      |> clamp_limit()

    Source
    |> where([source], source.user_id == ^user_id)
    |> maybe_filter_project(Keyword.get(opts, :project_id))
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_source_type(Keyword.get(opts, :source_type))
    |> order_by([source], desc: source.inserted_at)
    |> limit(^limit)
    |> preload(:project)
    |> Repo.all()
  end

  def get_source(%User{id: user_id}, id), do: get_source(user_id, id)

  def get_source(user_id, id) do
    case parse_id(id) do
      {:ok, source_id} ->
        Source
        |> where([source], source.user_id == ^user_id and source.id == ^source_id)
        |> preload(:project)
        |> Repo.one()

      :error ->
        nil
    end
  end

  def ingest_source(user_or_id, attrs), do: create_source(user_or_id, attrs)

  def create_source(%User{id: user_id}, attrs), do: create_source(user_id, attrs)

  def create_source(user_id, attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, attrs} <- resolve_project_id(user_id, attrs) do
      attrs =
        attrs
        |> Map.put("user_id", user_id)
        |> Map.put_new("status", "received")
        |> maybe_put_raw_hash()

      %Source{}
      |> Source.changeset(attrs)
      |> Repo.insert()
    end
  end

  def source_types, do: Source.source_types()
  def source_statuses, do: Source.statuses()
  def project_statuses, do: Project.statuses()

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} ->
      key = to_string(key)
      {key, normalize_value(key, value)}
    end)
  end

  defp normalize_attrs(_attrs), do: %{}

  defp normalize_value("tags", value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_value(_key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_value(_key, value), do: value

  defp resolve_project_id(user_id, attrs) do
    cond do
      is_nil(attrs["project_id"]) ->
        resolve_project_slug(user_id, attrs)

      match?({:ok, _id}, parse_id(attrs["project_id"])) ->
        {:ok, project_id} = parse_id(attrs["project_id"])

        if get_project(user_id, project_id) do
          {:ok, Map.put(attrs, "project_id", project_id)}
        else
          {:error, :project_not_found}
        end

      true ->
        {:error, :invalid_project_id}
    end
  end

  defp resolve_project_slug(user_id, %{"project_slug" => slug} = attrs) when is_binary(slug) do
    case get_project_by_slug(user_id, slug) do
      %Project{id: project_id} -> {:ok, Map.put(attrs, "project_id", project_id)}
      nil -> {:error, :project_not_found}
    end
  end

  defp resolve_project_slug(_user_id, attrs), do: {:ok, attrs}

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> {:ok, id}
      _other -> :error
    end
  end

  defp parse_id(_id), do: :error

  # Plaintext sources get a server-computed content hash for dedup. Encrypted
  # sources keep whatever blind HMAC the client supplied (or none) — the server
  # never sees the plaintext, so it cannot and must not hash it.
  defp maybe_put_raw_hash(attrs) do
    if encrypted?(attrs["encrypted"]) do
      attrs
    else
      Map.put_new(attrs, "raw_hash", raw_hash(attrs))
    end
  end

  defp encrypted?(true), do: true
  defp encrypted?("true"), do: true
  defp encrypted?(_), do: false

  defp raw_hash(attrs) do
    attrs
    |> Map.take(["source_type", "title", "url", "content", "content_format", "metadata", "tags"])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} -> clamp_limit(limit)
      _other -> @default_source_limit
    end
  end

  defp clamp_limit(limit) when is_integer(limit), do: min(max(limit, 1), @max_source_limit)
  defp clamp_limit(_limit), do: @default_source_limit

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, project_id),
    do: where(query, [source], source.project_id == ^project_id)

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [source], source.status == ^status)

  defp maybe_filter_source_type(query, nil), do: query

  defp maybe_filter_source_type(query, type),
    do: where(query, [source], source.source_type == ^type)
end
