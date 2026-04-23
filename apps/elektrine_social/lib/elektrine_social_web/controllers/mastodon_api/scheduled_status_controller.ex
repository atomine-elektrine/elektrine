defmodule ElektrineSocialWeb.MastodonAPI.ScheduledStatusController do
  @moduledoc """
  Mastodon-compatible scheduled status endpoints backed by drafts.
  """

  use ElektrineSocialWeb, :controller

  import Ecto.Query

  alias Elektrine.Repo
  alias Elektrine.Social.Drafts
  alias Elektrine.Social.Message

  action_fallback(ElektrineSocialWeb.MastodonAPI.FallbackController)

  def index(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def index(%{assigns: %{user: user}} = conn, params) do
    drafts =
      from(m in Message,
        where:
          m.sender_id == ^user.id and m.is_draft == true and not is_nil(m.scheduled_at) and
            is_nil(m.deleted_at),
        order_by: [asc: m.scheduled_at],
        limit: ^parse_limit(params["limit"], 20)
      )
      |> Repo.all()

    json(conn, Enum.map(drafts, &render_scheduled_status/1))
  end

  def show(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def show(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, draft} <- fetch_draft(user.id, id) do
      json(conn, render_scheduled_status(draft))
    end
  end

  def update(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def update(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, draft} <- fetch_draft(user.id, id),
         {:ok, updated} <-
           Drafts.update_draft(draft.id, user.id,
             scheduled_at: parse_datetime(params["scheduled_at"]),
             content: params["status"] || draft.content,
             content_warning: params["spoiler_text"] || draft.content_warning
           ) do
      json(conn, render_scheduled_status(updated))
    end
  end

  def delete(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def delete(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, draft} <- fetch_draft(user.id, id),
         {:ok, _} <- Drafts.delete_draft(draft.id, user.id) do
      json(conn, %{})
    end
  end

  defp fetch_draft(user_id, id) do
    case Drafts.get_draft(parse_int(id), user_id) do
      %{scheduled_at: scheduled_at} = draft when not is_nil(scheduled_at) -> {:ok, draft}
      _ -> {:error, :not_found}
    end
  end

  defp render_scheduled_status(draft) do
    %{
      id: to_string(draft.id),
      scheduled_at: DateTime.to_iso8601(draft.scheduled_at),
      params: %{
        text: draft.content || "",
        media_ids: draft.media_urls || [],
        sensitive: draft.sensitive || false,
        spoiler_text: draft.content_warning || "",
        visibility: draft.visibility || "public"
      }
    }
  end

  defp parse_limit(nil, default), do: default

  defp parse_limit(value, default) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> min(max(int, 1), 40)
      _ -> default
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
