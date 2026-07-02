defmodule ElektrineWeb.API.AnnouncementController do
  @moduledoc """
  JSON API for active system announcements.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Admin

  def index(conn, _params) do
    user = conn.assigns[:current_user]

    announcements =
      user.id
      |> Admin.list_active_announcements_for_user()
      |> Enum.map(&format_announcement/1)

    json(conn, announcements)
  end

  def dismiss(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case parse_id(id) do
      {:ok, announcement_id} ->
        dismiss_for_user(conn, user.id, announcement_id)

      :error ->
        not_found(conn)
    end
  end

  defp dismiss_for_user(conn, user_id, announcement_id) do
    if active_announcement?(user_id, announcement_id) do
      case Admin.dismiss_announcement_for_user(user_id, announcement_id) do
        {:ok, _dismissal} ->
          json(conn, %{id: to_string(announcement_id), dismissed: true})

        {:error, changeset} ->
          if already_dismissed?(changeset) do
            json(conn, %{id: to_string(announcement_id), dismissed: true})
          else
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
          end
      end
    else
      not_found(conn)
    end
  end

  defp active_announcement?(_user_id, announcement_id) do
    announcement_id
    |> Admin.get_announcement!()
    |> Elektrine.Admin.Announcement.currently_active?()
  rescue
    Ecto.NoResultsError -> false
  end

  defp already_dismissed?(changeset) do
    Enum.any?(changeset.errors, fn
      {:user_id, {_message, opts}} ->
        opts[:constraint] == :unique

      {_field, {_message, opts}} ->
        opts[:constraint_name] == "announcement_dismissals_user_id_announcement_id_index"
    end)
  end

  defp format_announcement(announcement) do
    %{
      id: to_string(announcement.id),
      type: announcement.type,
      title: announcement.title,
      content: announcement.content,
      starts_at: announcement.starts_at,
      ends_at: announcement.ends_at,
      published: announcement.active,
      all_day: false,
      read: false,
      mentions: [],
      statuses: [],
      tags: [],
      emojis: [],
      reactions: []
    }
  end

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_id(_value), do: :error

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end
end
