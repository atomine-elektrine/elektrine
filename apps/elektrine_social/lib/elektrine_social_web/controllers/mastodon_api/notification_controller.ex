defmodule ElektrineSocialWeb.MastodonAPI.NotificationController do
  @moduledoc """
  Mastodon-compatible notification listing and dismissal.
  """

  use ElektrineSocialWeb, :controller

  alias Elektrine.Messaging.Messages
  alias Elektrine.Notifications
  alias ElektrineSocialWeb.MastodonAPI.StatusView

  action_fallback(ElektrineSocialWeb.MastodonAPI.FallbackController)

  def index(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def index(%{assigns: %{user: user}} = conn, params) do
    notifications =
      Notifications.list_notifications(user.id, limit: parse_limit(params["limit"], 20))
      |> Enum.map(&render_notification(&1, user))

    json(conn, notifications)
  end

  def dismiss(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def dismiss(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    Notifications.dismiss_notification(parse_int(id), user.id)
    json(conn, %{})
  end

  defp render_notification(notification, user) do
    %{
      id: to_string(notification.id),
      type: mastodon_notification_type(notification.type),
      created_at:
        notification.inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601(),
      account:
        if(notification.actor, do: StatusView.render_account(notification.actor, user), else: nil),
      status: render_notification_status(notification, user)
    }
  end

  defp render_notification_status(%{source_type: "message", source_id: source_id}, user)
       when is_integer(source_id) do
    case Messages.get_timeline_post(source_id) do
      nil -> nil
      post -> StatusView.render_status(post, user)
    end
  end

  defp render_notification_status(%{source_type: "post", source_id: source_id}, user)
       when is_integer(source_id) do
    case Messages.get_timeline_post(source_id) do
      nil -> nil
      post -> StatusView.render_status(post, user)
    end
  end

  defp render_notification_status(_, _), do: nil

  defp mastodon_notification_type("new_message"), do: "mention"
  defp mastodon_notification_type("comment"), do: "mention"
  defp mastodon_notification_type("discussion_reply"), do: "mention"

  defp mastodon_notification_type(type) when type in ["mention", "reply", "follow", "like"] do
    if type == "like", do: "favourite", else: type
  end

  defp mastodon_notification_type(_), do: "mention"

  defp parse_limit(nil, default), do: default

  defp parse_limit(value, default) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> min(max(int, 1), 40)
      _ -> default
    end
  end

  defp parse_int(nil), do: 0
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end
end
