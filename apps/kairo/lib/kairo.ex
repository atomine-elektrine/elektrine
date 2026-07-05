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
  @max_source_limit 1000

  def list_projects(user_or_id, opts \\ [])

  def list_projects(%User{id: user_id}, opts), do: list_projects(user_id, opts)

  def list_projects(user_id, opts) do
    Project
    |> where([project], project.user_id == ^user_id)
    |> maybe_filter_project_status(Keyword.get(opts, :status))
    |> order_by([project], asc: project.name)
    |> Repo.all()
  end

  defp maybe_filter_project_status(query, nil), do: query

  defp maybe_filter_project_status(query, status),
    do: where(query, [project], project.status == ^status)

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
    |> tap_storage_update(user_id)
  end

  def update_project(%User{id: user_id}, id, attrs), do: update_project(user_id, id, attrs)

  def update_project(user_id, id, attrs) do
    case get_project(user_id, id) do
      %Project{} = project ->
        project
        |> Project.changeset(strip_owner_attrs(normalize_attrs(attrs)))
        |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end

  # Deleting a project releases its sources back to the inbox (the FK nilifies
  # project_id); only the grouping is destroyed.
  def delete_project(%User{id: user_id}, id), do: delete_project(user_id, id)

  def delete_project(user_id, id) do
    case get_project(user_id, id) do
      %Project{} = project ->
        project
        |> Repo.delete()
        |> tap_storage_update(user_id)

      nil ->
        {:error, :not_found}
    end
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
    |> order_by([source], desc: source.inserted_at, desc: source.id)
    |> limit(^limit)
    |> offset(^clamp_offset(Keyword.get(opts, :offset)))
    |> preload(:project)
    |> Repo.all()
    |> Enum.map(&decrypt_at_rest_content/1)
  end

  def count_sources(user_or_id, opts \\ [])

  def count_sources(%User{id: user_id}, opts), do: count_sources(user_id, opts)

  def count_sources(user_id, opts) do
    Source
    |> where([source], source.user_id == ^user_id)
    |> maybe_filter_project(Keyword.get(opts, :project_id))
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_source_type(Keyword.get(opts, :source_type))
    |> Repo.aggregate(:count)
  end

  def get_source(%User{id: user_id}, id), do: get_source(user_id, id)

  def get_source(user_id, id) do
    case parse_id(id) do
      {:ok, source_id} ->
        Source
        |> where([source], source.user_id == ^user_id and source.id == ^source_id)
        |> preload(:project)
        |> Repo.one()
        |> decrypt_at_rest_content()

      :error ->
        nil
    end
  end

  # Restores plaintext `content` from the server-side at-rest ciphertext for
  # reads. Zero-knowledge sources have no `content_encrypted` and stay untouched
  # (their `encrypted_content` is decrypted client-side).
  defp decrypt_at_rest_content(nil), do: nil

  defp decrypt_at_rest_content(%Source{content_encrypted: enc, user_id: user_id} = source)
       when is_map(enc) and is_integer(user_id) do
    case Elektrine.Encryption.decrypt(enc, user_id) do
      {:ok, plaintext} -> %{source | content: plaintext}
      _error -> source
    end
  end

  defp decrypt_at_rest_content(source), do: source

  def ingest_source(user_or_id, attrs), do: create_source(user_or_id, attrs)

  def create_source(%User{id: user_id}, attrs), do: create_source(user_id, attrs)

  def create_source(user_id, attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, attrs} <- resolve_project_id(user_id, attrs) do
      attrs =
        attrs
        |> Map.put("user_id", user_id)
        |> Map.put_new("status", "received")

      case %Source{} |> Source.changeset(attrs) |> Repo.insert() |> tap_storage_update(user_id) do
        {:ok, source} ->
          maybe_enqueue_url_fetch(source)
          {:ok, decrypt_at_rest_content(source)}

        {:error, %Ecto.Changeset{} = changeset} ->
          # Idempotent ingest: re-submitting identical content returns the
          # already-stored source instead of an error.
          case existing_duplicate(user_id, changeset) do
            %Source{} = source -> {:ok, source}
            nil -> {:error, changeset}
          end

        other ->
          other
      end
    end
  end

  defp existing_duplicate(user_id, changeset) do
    raw_hash = Ecto.Changeset.get_field(changeset, :raw_hash)

    with true <- duplicate_error?(changeset),
         true <- is_binary(raw_hash) do
      Source
      |> where([source], source.user_id == ^user_id and source.raw_hash == ^raw_hash)
      |> preload(:project)
      |> Repo.one()
      |> decrypt_at_rest_content()
    else
      _ -> nil
    end
  end

  defp duplicate_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:raw_hash, {_message, meta}} -> meta[:constraint] == :unique
      _other -> false
    end)
  end

  # URL sources ingested without a body are hydrated by a background fetch.
  defp maybe_enqueue_url_fetch(%Source{} = source) do
    if source.source_type == "url" and not source.encrypted and
         is_nil(source.content_encrypted) and is_binary(source.url) and
         source.status == "received" and
         Application.get_env(:elektrine, :kairo_fetch_url_sources, true) do
      _ = Kairo.UrlFetchWorker.enqueue(source)
    end

    :ok
  end

  def update_source(%User{id: user_id}, id, attrs), do: update_source(user_id, id, attrs)

  def update_source(user_id, id, attrs) do
    case get_source(user_id, id) do
      %Source{} = source ->
        attrs = strip_owner_attrs(normalize_attrs(attrs))

        with {:ok, attrs} <- resolve_project_id(user_id, attrs) do
          case source
               |> Source.changeset(attrs)
               |> Repo.update()
               |> tap_storage_update(user_id) do
            {:ok, source} -> {:ok, decrypt_at_rest_content(source)}
            other -> other
          end
        end

      nil ->
        {:error, :not_found}
    end
  end

  def delete_source(%User{id: user_id}, id), do: delete_source(user_id, id)

  def delete_source(user_id, id) do
    case get_source(user_id, id) do
      %Source{} = source ->
        source
        |> Repo.delete()
        |> tap_storage_update(user_id)

      nil ->
        {:error, :not_found}
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

  # Attrs that clients must never set on an existing record - ownership is
  # fixed at create time.
  defp strip_owner_attrs(attrs), do: Map.drop(attrs, ["user_id", "id"])

  defp clamp_offset(offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {offset, ""} -> clamp_offset(offset)
      _other -> 0
    end
  end

  defp clamp_offset(offset) when is_integer(offset) and offset > 0, do: offset
  defp clamp_offset(_offset), do: 0

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

  defp tap_storage_update({:ok, _schema} = result, user_id) do
    _ = Elektrine.Accounts.Storage.update_user_storage(user_id)
    result
  end

  defp tap_storage_update(result, _user_id), do: result
end
