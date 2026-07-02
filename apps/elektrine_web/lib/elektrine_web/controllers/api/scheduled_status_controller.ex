defmodule ElektrineWeb.API.ScheduledStatusController do
  @moduledoc """
  Mastodon-compatible scheduled status API backed by Elektrine scheduled drafts.
  """
  use ElektrineWeb, :controller

  action_fallback ElektrineWeb.FallbackController

  def index(conn, params) do
    user = conn.assigns[:current_user]
    limit = parse_int(params["limit"], 20)

    statuses =
      drafts().list_scheduled_drafts(user.id, limit: limit)
      |> Enum.map(&format_scheduled_status/1)

    json(conn, statuses)
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case drafts().get_scheduled_draft(id, user.id) do
      nil -> not_found(conn)
      draft -> json(conn, format_scheduled_status(draft))
    end
  end

  def create(conn, params) do
    user = conn.assigns[:current_user]

    with {:ok, scheduled_at} <- parse_scheduled_at(params["scheduled_at"]),
         {:ok, draft} <-
           drafts().create_draft(user.id, draft_opts(params, scheduled_at)) do
      conn
      |> put_status(:created)
      |> json(format_scheduled_status(draft))
    else
      {:error, :missing_schedule} ->
        bad_request(conn, "scheduled_at is required")

      {:error, :invalid_schedule} ->
        bad_request(conn, "scheduled_at must be an ISO8601 datetime")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with {:ok, scheduled_at} <- parse_optional_scheduled_at(params),
         {:ok, draft} <-
           drafts().update_scheduled_draft(
             id,
             user.id,
             update_draft_opts(params, scheduled_at)
           ) do
      json(conn, format_scheduled_status(draft))
    else
      {:error, :not_found} ->
        not_found(conn)

      {:error, :invalid_schedule} ->
        bad_request(conn, "scheduled_at must be an ISO8601 datetime")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case drafts().delete_draft(id, user.id) do
      {:ok, _draft} -> json(conn, %{id: to_string(id), deleted: true})
      {:error, :not_found} -> not_found(conn)
    end
  end

  def publish(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case drafts().publish_draft(id, user.id) do
      {:ok, post} ->
        json(conn, %{id: to_string(post.id), scheduled_status_id: to_string(id), published: true})

      {:error, :scheduled_for_future} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "scheduled status is not due yet"})

      {:error, :not_found} ->
        not_found(conn)

      {:error, reason} ->
        bad_request(conn, to_string(reason))
    end
  end

  defp draft_opts(params, scheduled_at) do
    [
      content: params["status"] || params["content"] || "",
      title: params["title"],
      visibility: params["visibility"] || "followers",
      media_urls: normalize_list(params["media_urls"]),
      content_warning: params["spoiler_text"] || params["content_warning"],
      sensitive: truthy?(params["sensitive"]),
      scheduled_at: scheduled_at
    ]
  end

  defp update_draft_opts(params, scheduled_at) do
    []
    |> maybe_put(:content, params["status"] || params["content"])
    |> maybe_put(:title, params["title"])
    |> maybe_put(:visibility, params["visibility"])
    |> maybe_put(:media_urls, maybe_list(params["media_urls"]))
    |> maybe_put(:content_warning, params["spoiler_text"] || params["content_warning"])
    |> maybe_put(:sensitive, maybe_boolean(params["sensitive"]))
    |> maybe_put(:scheduled_at, if(scheduled_at == :unchanged, do: nil, else: scheduled_at))
  end

  defp drafts, do: Module.concat([Elektrine, Social, Drafts])

  defp format_scheduled_status(draft) do
    %{
      id: to_string(draft.id),
      scheduled_at: draft.scheduled_at,
      params: %{
        text: draft.content || "",
        spoiler_text: draft.content_warning || "",
        sensitive: draft.sensitive || false,
        visibility: draft.visibility || "followers",
        media_ids: [],
        poll: nil
      },
      media_attachments: format_media_urls(draft.media_urls || [])
    }
  end

  defp format_media_urls(urls) do
    urls
    |> normalize_list()
    |> Enum.map(fn url ->
      %{id: url, type: "unknown", url: url, preview_url: url, description: nil}
    end)
  end

  defp parse_scheduled_at(nil), do: {:error, :missing_schedule}
  defp parse_scheduled_at(""), do: {:error, :missing_schedule}

  defp parse_scheduled_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      _ -> {:error, :invalid_schedule}
    end
  end

  defp parse_scheduled_at(_), do: {:error, :invalid_schedule}

  defp parse_optional_scheduled_at(%{"scheduled_at" => value}), do: parse_scheduled_at(value)
  defp parse_optional_scheduled_at(_), do: {:ok, :unchanged}

  defp normalize_list(nil), do: []
  defp normalize_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp normalize_list(value) when is_binary(value), do: [value]
  defp normalize_list(_), do: []

  defp maybe_list(nil), do: nil
  defp maybe_list(value), do: normalize_list(value)

  defp maybe_boolean(nil), do: nil
  defp maybe_boolean(value), do: truthy?(value)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_int(_, default), do: default

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end

  defp bad_request(conn, error) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: error})
  end
end
