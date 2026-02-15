defmodule ElektrineWeb.API.NotificationController do
  @moduledoc """
  API controller for notifications.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Notifications

  action_fallback ElektrineWeb.FallbackController

  @doc """
  GET /api/notifications
  Lists notifications for the current user.

  Query params:
    - limit: Number of notifications to return (default 50)
    - offset: Offset for pagination (default 0)
    - filter: "all", "unread", or "unseen" (default "all")
  """
  def index(conn, params) do
    user = conn.assigns[:current_user]

    limit = parse_int(params["limit"], 50)
    offset = parse_int(params["offset"], 0)

    filter =
      case params["filter"] do
        "unread" -> :unread
        "unseen" -> :unseen
        _ -> :all
      end

    notifications =
      Notifications.list_notifications(user.id, limit: limit, offset: offset, filter: filter)

    unread_count = Notifications.get_unread_count(user.id)

    conn
    |> put_status(:ok)
    |> json(%{
      notifications: Enum.map(notifications, &format_notification/1),
      unread_count: unread_count,
      limit: limit,
      offset: offset
    })
  end

  @doc """
  POST /api/notifications/:id/read
  Marks a notification as read.
  """
  def mark_read(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    Notifications.mark_as_read(parse_int(id, 0), user.id)

    conn
    |> put_status(:ok)
    |> json(%{message: "Notification marked as read"})
  end

  @doc """
  POST /api/notifications/read-all
  Marks all notifications as read.
  """
  def mark_all_read(conn, _params) do
    user = conn.assigns[:current_user]

    Notifications.mark_all_as_read(user.id)

    conn
    |> put_status(:ok)
    |> json(%{message: "All notifications marked as read"})
  end

  @doc """
  DELETE /api/notifications/:id
  Dismisses a notification.
  """
  def dismiss(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    Notifications.dismiss_notification(parse_int(id, 0), user.id)

    conn
    |> put_status(:ok)
    |> json(%{message: "Notification dismissed"})
  end

  # Private helpers

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp format_notification(notification) do
    %{
      id: notification.id,
      type: notification.type,
      title: notification.title,
      body: notification.body,
      url: notification.url,
      icon: notification.icon,
      read: not is_nil(notification.read_at),
      seen: not is_nil(notification.seen_at),
      actor: format_actor(notification.actor),
      source_type: notification.source_type,
      source_id: notification.source_id,
      inserted_at: notification.inserted_at
    }
  end

  defp format_actor(nil), do: nil

  defp format_actor(actor) do
    %{
      id: actor.id,
      username: actor.username,
      display_name: actor.display_name,
      avatar_url: actor.avatar_url
    }
  end
end
