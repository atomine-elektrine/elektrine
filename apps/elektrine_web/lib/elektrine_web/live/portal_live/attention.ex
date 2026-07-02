defmodule ElektrineWeb.PortalLive.Attention do
  @moduledoc false

  @filters ~w(all email chat requests social system)

  def queue(
        inbox_messages,
        recent_notifications,
        inbox_unread_count,
        notifications_unread_count,
        reply_later_count,
        chat_unread_count,
        pending_friend_requests_count,
        pending_follow_requests_count
      ) do
    unread_email_messages =
      inbox_messages
      |> Enum.filter(&(Map.get(&1, :read, false) == false))
      |> Enum.take(3)

    remaining_unread_count = max(inbox_unread_count - length(unread_email_messages), 0)

    remaining_notification_count =
      max(notifications_unread_count - min(length(recent_notifications), 4), 0)

    unread_email_items = Enum.map(unread_email_messages, &build_unread_email_item/1)

    request_items =
      [
        if pending_friend_requests_count > 0 do
          %{
            id: "attention-friend-requests",
            source: "requests",
            title: "Respond to friend requests",
            detail: "#{pending_friend_requests_count} request(s) waiting",
            href: Elektrine.Paths.friends_path(tab: "requests"),
            icon: "hero-user-plus",
            priority: "high",
            state: "pending",
            at: nil,
            actions: [
              attention_action("Open", Elektrine.Paths.friends_path(tab: "requests")),
              attention_action("Follow", Elektrine.Paths.friends_path(tab: "requests"))
            ]
          }
        end,
        if pending_follow_requests_count > 0 do
          %{
            id: "attention-follow-requests",
            source: "requests",
            title: "Review fediverse follow approvals",
            detail: "#{pending_follow_requests_count} approval(s) waiting",
            href: Elektrine.Paths.friends_path(tab: "requests"),
            icon: "hero-globe-americas",
            priority: "high",
            state: "approval",
            at: nil,
            actions: [
              attention_action("Open", Elektrine.Paths.friends_path(tab: "requests")),
              attention_action("Follow", Elektrine.Paths.friends_path(tab: "requests"))
            ]
          }
        end
      ]

    backlog_items =
      [
        if remaining_unread_count > 0 do
          %{
            id: "attention-more-email",
            source: "email",
            title: "More unread email waiting",
            detail: "#{remaining_unread_count} more unread message(s)",
            href: Elektrine.Paths.email_index_path(tab: "inbox", filter: "unread"),
            icon: "hero-envelope",
            priority: "high",
            state: "backlog",
            at: nil,
            actions: [
              attention_action(
                "Open",
                Elektrine.Paths.email_index_path(tab: "inbox", filter: "unread")
              ),
              attention_action("Move", Elektrine.Paths.email_index_path(tab: "inbox"))
            ]
          }
        end,
        if reply_later_count > 0 do
          %{
            id: "attention-reply-later",
            source: "email",
            title: "Handle reply-later reminders",
            detail: "#{reply_later_count} reminder(s) due",
            href: Elektrine.Paths.email_index_path(tab: "inbox", filter: "boomerang"),
            icon: "hero-arrow-uturn-left",
            priority: "medium",
            state: "remind",
            at: nil,
            actions: [
              attention_action(
                "Open",
                Elektrine.Paths.email_index_path(tab: "inbox", filter: "boomerang")
              ),
              attention_action(
                "Remind",
                Elektrine.Paths.email_index_path(tab: "inbox", filter: "boomerang")
              )
            ]
          }
        end,
        if chat_unread_count > 0 do
          %{
            id: "attention-chat-unread",
            source: "chat",
            title: "Catch up on chat",
            detail: "#{chat_unread_count} unread message(s)",
            href: Elektrine.Paths.chat_root_path(),
            icon: "hero-chat-bubble-left-right",
            priority: "medium",
            state: "unread",
            at: nil,
            actions: [attention_action("Open", Elektrine.Paths.chat_root_path())]
          }
        end,
        if remaining_notification_count > 0 do
          %{
            id: "attention-more-notifications",
            source: "social",
            title: "More notifications are stacked up",
            detail:
              "#{remaining_notification_count} unread notification(s) behind the latest items",
            href: Elektrine.Paths.notifications_path(),
            icon: "hero-bell-alert",
            priority: "medium",
            state: "backlog",
            at: nil,
            actions: [attention_action("Open", Elektrine.Paths.notifications_path())]
          }
        end
      ]

    notification_items =
      recent_notifications
      |> Enum.take(4)
      |> Enum.map(&build_notification_item/1)

    (unread_email_items ++ request_items ++ backlog_items ++ notification_items)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn item ->
      {priority_rank(item.priority), -sort_datetime(item.at)}
    end)
    |> Enum.take(12)
  end

  def counts(queue) do
    base_counts =
      Enum.reduce(@filters, %{}, fn filter, acc ->
        Map.put(acc, filter, 0)
      end)

    queue
    |> Enum.reduce(base_counts, fn item, acc ->
      Map.update(acc, item.source, 1, &(&1 + 1))
    end)
    |> Map.put("all", length(queue))
  end

  def filtered_queue(queue, "all"), do: queue

  def filtered_queue(queue, filter) do
    Enum.filter(queue, &(&1.source == filter))
  end

  def filter_label("all"), do: "All"
  def filter_label("email"), do: "Email"
  def filter_label("chat"), do: "Chat"
  def filter_label("requests"), do: "Requests"
  def filter_label("social"), do: "Social"
  def filter_label("system"), do: "System"
  def filter_label(filter), do: String.capitalize(filter)

  def source_badge_class("email"), do: "badge badge-info badge-xs"
  def source_badge_class("chat"), do: "badge badge-primary badge-xs"
  def source_badge_class("requests"), do: "badge badge-warning badge-xs"
  def source_badge_class("social"), do: "badge badge-secondary badge-xs"
  def source_badge_class(_source), do: "badge badge-ghost badge-xs"

  defp build_unread_email_item(message) do
    href = Elektrine.Paths.email_view_path(message)

    %{
      id: "attention-email-#{message.id}",
      source: "email",
      title: inbox_subject(message),
      detail: "From #{inbox_sender(message.from)}",
      href: href,
      icon: "hero-envelope",
      priority: "high",
      state: "unread",
      at: message.inserted_at,
      actions: [
        attention_action("Open", href),
        attention_action("Move", Elektrine.Paths.email_index_path(tab: "inbox")),
        attention_action(
          "Remind",
          Elektrine.Paths.email_index_path(tab: "inbox", filter: "boomerang")
        )
      ]
    }
  end

  defp build_notification_item(notification) do
    source = notification_source(notification)
    href = normalize_internal_path(notification.url)

    %{
      id: "attention-notification-#{notification.id}",
      source: source,
      title: trim_or(notification.title, "Notification"),
      detail: notification_detail(notification),
      href: href,
      icon: notification_icon(notification),
      priority: notification_priority(notification),
      state: "unread",
      at: notification.inserted_at,
      actions: attention_actions_for_source(source, href)
    }
  end

  defp attention_actions_for_source("email", href) do
    [
      attention_action("Open", href),
      attention_action("Move", Elektrine.Paths.email_index_path(tab: "inbox")),
      attention_action(
        "Remind",
        Elektrine.Paths.email_index_path(tab: "inbox", filter: "boomerang")
      )
    ]
  end

  defp attention_actions_for_source("requests", href) do
    [attention_action("Open", href), attention_action("Follow", href)]
  end

  defp attention_actions_for_source("social", href) do
    [
      attention_action("Open", href),
      attention_action("Save", Elektrine.Paths.timeline_path(filter: "saved", view: "all")),
      attention_action("Share", Elektrine.Paths.timeline_path(composer: "post"))
    ]
  end

  defp attention_actions_for_source(_source, href) do
    [attention_action("Open", href)]
  end

  defp attention_action(label, href), do: %{label: label, href: href}

  defp priority_rank("high"), do: 0
  defp priority_rank("medium"), do: 1
  defp priority_rank(_priority), do: 2

  @social_notification_types ~w(follow mention like boost reaction status poll update comment discussion_reply)

  defp notification_source(notification) do
    case {notification.type, notification.source_type} do
      {"email_received", _} -> "email"
      {"reply", source} when source in ["post", "discussion"] -> "social"
      {type, _} when type in @social_notification_types -> "social"
      {_, "message"} -> "chat"
      {_, "post"} -> "social"
      {_, "discussion"} -> "social"
      _ -> "system"
    end
  end

  defp notification_priority(notification) do
    case notification.type do
      "mention" -> "high"
      "reply" -> "high"
      "email_received" -> "medium"
      "new_message" -> "medium"
      "follow" -> "medium"
      _ -> "low"
    end
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

  defp normalize_internal_path(path) when is_binary(path) do
    path = String.trim(path)

    if String.starts_with?(path, "/") do
      path
    else
      Elektrine.Paths.notifications_path()
    end
  end

  defp normalize_internal_path(_), do: Elektrine.Paths.notifications_path()

  defp sort_datetime(%DateTime{} = datetime), do: DateTime.to_unix(datetime)

  defp sort_datetime(%NaiveDateTime{} = datetime) do
    DateTime.from_naive!(datetime, "Etc/UTC") |> DateTime.to_unix()
  end

  defp sort_datetime(_), do: 0
end
