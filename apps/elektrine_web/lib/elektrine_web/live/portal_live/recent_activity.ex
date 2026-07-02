defmodule ElektrineWeb.PortalLive.RecentActivity do
  @moduledoc false

  def build(inbox_messages, recent_conversations, recent_posts, recent_notifications, vpn_configs) do
    email_items =
      inbox_messages
      |> Enum.take(3)
      |> Enum.map(fn message ->
        %{
          id: "email-#{message.id}",
          app: "Email",
          title: inbox_subject(message),
          detail: "From #{inbox_sender(message.from)}",
          href: Elektrine.Paths.email_view_path(message),
          icon: "hero-envelope",
          at: message.inserted_at
        }
      end)

    chat_items =
      recent_conversations
      |> Enum.take(3)
      |> Enum.map(fn conversation ->
        %{
          id: "chat-#{conversation.id}",
          app: "Chat",
          title: conversation_label(conversation),
          detail: String.capitalize(conversation.type || "conversation"),
          href: Elektrine.Paths.chat_path(conversation),
          icon: "hero-chat-bubble-left-right",
          at: conversation.last_message_at || conversation.updated_at || conversation.inserted_at
        }
      end)

    social_items =
      recent_posts
      |> Enum.take(3)
      |> Enum.map(fn post ->
        %{
          id: "social-#{post.id}",
          app: "Social",
          title: social_post_title(post),
          detail: "Timeline update",
          href: Elektrine.Paths.post_path(post.id),
          icon: "hero-rectangle-stack",
          at: post.inserted_at
        }
      end)

    notification_items =
      recent_notifications
      |> Enum.take(3)
      |> Enum.map(fn notification ->
        %{
          id: "notification-#{notification.id}",
          app: notification_app(notification),
          title: trim_or(notification.title, "Notification"),
          detail: notification_detail(notification),
          href: normalize_internal_path(notification.url),
          icon: notification_icon(notification),
          at: notification.inserted_at
        }
      end)

    vpn_items =
      case Enum.max_by(vpn_configs, &sort_datetime(&1.updated_at || &1.inserted_at), fn -> nil end) do
        nil ->
          []

        config ->
          [
            %{
              id: "vpn-#{config.id}",
              app: "VPN",
              title: "VPN profile ready",
              detail: trim_or(config.vpn_server && config.vpn_server.name, "VPN config"),
              href: Elektrine.Paths.vpn_path(),
              icon: "hero-shield-check",
              at: config.updated_at || config.inserted_at
            }
          ]
      end

    (email_items ++ chat_items ++ social_items ++ notification_items ++ vpn_items)
    |> Enum.sort_by(&sort_datetime(&1.at), :desc)
    |> Enum.take(10)
  end

  defp inbox_subject(%{subject: subject}) when is_binary(subject) do
    subject |> trim_or("(No subject)") |> truncate_text(72)
  end

  defp inbox_subject(_), do: "(No subject)"

  defp inbox_sender(from) do
    from |> trim_or("Unknown sender") |> extract_sender_name() |> truncate_text(42)
  end

  defp extract_sender_name(from) when is_binary(from) do
    case Regex.run(~r/^(.+?)\s*<(.+)>$/, from) do
      [_, name, _email] -> name |> String.trim() |> String.trim("\"") |> trim_or(from)
      _ -> from
    end
  end

  defp extract_sender_name(from), do: from

  defp conversation_label(conversation) do
    name = trim_or(conversation.name, "")

    cond do
      Elektrine.Strings.present?(name) -> name
      conversation.type == "dm" -> "Direct message"
      true -> "Conversation ##{conversation.id}"
    end
  end

  defp social_post_title(post) do
    post
    |> then(fn post ->
      ElektrineWeb.HtmlHelpers.plain_text_content(post.title || post.content)
    end)
    |> trim_or("New social post")
    |> truncate_text(72)
  end

  defp notification_app(notification) do
    case {notification.type, notification.source_type} do
      {"email_received", _} -> "Email"
      {"follow", _} -> "Social"
      {"mention", _} -> "Social"
      {"reply", source} when source in ["post", "discussion"] -> "Social"
      {"like", _} -> "Social"
      {"boost", _} -> "Social"
      {"reaction", _} -> "Social"
      {"status", _} -> "Social"
      {"poll", _} -> "Social"
      {"update", _} -> "Social"
      {"comment", _} -> "Social"
      {"discussion_reply", _} -> "Social"
      {_, "message"} -> "Chat"
      {_, "post"} -> "Social"
      {_, "discussion"} -> "Social"
      _ -> "Alerts"
    end
  end

  defp notification_icon(notification) do
    case notification.type do
      "email_received" -> "hero-envelope"
      "new_message" -> "hero-chat-bubble-left-right"
      "reply" -> "hero-chat-bubble-left"
      "follow" -> "hero-user-plus"
      "mention" -> "hero-at-symbol"
      "like" -> "hero-heart"
      "boost" -> "hero-arrow-path-rounded-square"
      "reaction" -> "hero-face-smile"
      "status" -> "hero-rectangle-stack"
      "poll" -> "hero-chart-bar"
      "update" -> "hero-pencil-square"
      "admin.sign_up" -> "hero-user-plus"
      "admin.report" -> "hero-shield-exclamation"
      _ -> "hero-bell"
    end
  end

  defp notification_detail(notification) do
    trim_or(notification.body, "Recent update") |> truncate_text(90)
  end

  defp normalize_internal_path(path) when is_binary(path) do
    path = String.trim(path)

    if String.starts_with?(path, "/") do
      path
    else
      Elektrine.Paths.notifications_path()
    end
  end

  defp normalize_internal_path(_), do: Elektrine.Paths.notifications_path()

  defp trim_or(value, fallback) when is_binary(value) do
    value = String.trim(value)

    Elektrine.Strings.present(value) || fallback
  end

  defp trim_or(_value, fallback), do: fallback

  defp truncate_text(text, max_length) when is_binary(text) and max_length > 1 do
    if String.length(text) > max_length do
      if max_length <= 3 do
        String.slice(text, 0, max_length)
      else
        String.slice(text, 0, max_length - 3) <> "..."
      end
    else
      text
    end
  end

  defp truncate_text(_text, _max_length), do: ""

  defp sort_datetime(%DateTime{} = datetime), do: DateTime.to_unix(datetime)

  defp sort_datetime(%NaiveDateTime{} = datetime) do
    DateTime.from_naive!(datetime, "Etc/UTC") |> DateTime.to_unix()
  end

  defp sort_datetime(_), do: 0
end
