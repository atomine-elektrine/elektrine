defmodule ElektrineWeb.PortalLive.DashboardData do
  @moduledoc false

  alias Elektrine.Platform.Modules

  def default do
    %{
      inbox_messages: [],
      inbox_unread_count: 0,
      chat_unread_count: 0,
      notifications_unread_count: 0,
      pending_friend_requests_count: 0,
      pending_follow_requests_count: 0,
      vpn_config_count: 0,
      credits: nil,
      tasks: [],
      alerts: [],
      attention_queue: [],
      attention_counts: %{"all" => 0},
      quick_actions: quick_actions(),
      recent_activity: []
    }
  end

  def quick_actions(user \\ nil) do
    [
      if module_available?(user, :email, :email) do
        %{
          id: "compose_email",
          label: "Compose Email",
          detail: "Start a new message",
          href: Elektrine.Paths.email_compose_path(return_to: "portal"),
          icon: "hero-pencil-square",
          tone: "primary"
        }
      end,
      if module_available?(user, :chat, :chat) do
        %{
          id: "new_message",
          label: "New Message",
          detail: "Start a direct message",
          href: Elektrine.Paths.chat_root_path(composer: "message"),
          icon: "hero-chat-bubble-left-right",
          tone: "neutral"
        }
      end,
      if module_available?(user, :social, :timeline) do
        %{
          id: "new_post",
          label: "New Post",
          detail: "Share an update",
          href: Elektrine.Paths.timeline_path(composer: "post"),
          icon: "hero-rectangle-stack",
          tone: "neutral"
        }
      end,
      if module_available?(user, :email, :email) do
        %{
          id: "new_task",
          label: "New Task",
          detail: "Capture work on the calendar",
          href: Elektrine.Paths.calendar_path(composer: "task"),
          icon: "hero-check-circle",
          tone: "neutral"
        }
      end,
      if module_available?(user, :social, :lists) do
        %{
          id: "new_list",
          label: "New List",
          detail: "Save a smaller group",
          href: Elektrine.Paths.lists_path("create-list-panel"),
          icon: "hero-queue-list",
          tone: "neutral"
        }
      end,
      %{
        id: "search",
        label: "Maid",
        detail: "Private search",
        href: Elektrine.Paths.maid_path(),
        icon: "hero-magnifying-glass",
        tone: "neutral"
      }
    ]
    |> Enum.reject(&is_nil/1)
  end

  def tasks(
        inbox_unread_count,
        reply_later_count,
        chat_unread_count,
        pending_friend_requests_count,
        pending_follow_requests_count,
        vpn_config_count
      ) do
    [
      if inbox_unread_count > 0 do
        %{
          id: "review_inbox",
          title: "Review unread inbox",
          detail: "#{inbox_unread_count} message(s) waiting",
          href: Elektrine.Paths.email_index_path(tab: "inbox", filter: "unread"),
          icon: "hero-envelope",
          priority: "high"
        }
      end,
      if reply_later_count > 0 do
        %{
          id: "reply_later",
          title: "Handle boomerang reminders",
          detail: "#{reply_later_count} follow-up reminder(s)",
          href: Elektrine.Paths.email_index_path(tab: "inbox", filter: "boomerang"),
          icon: "hero-arrow-uturn-left",
          priority: "medium"
        }
      end,
      if pending_friend_requests_count > 0 do
        %{
          id: "friend_requests",
          title: "Respond to friend requests",
          detail: "#{pending_friend_requests_count} pending request(s)",
          href: Elektrine.Paths.friends_path(tab: "requests"),
          icon: "hero-user-plus",
          priority: "medium"
        }
      end,
      if pending_follow_requests_count > 0 do
        %{
          id: "follow_requests",
          title: "Review fediverse follows",
          detail: "#{pending_follow_requests_count} remote request(s)",
          href: Elektrine.Paths.friends_path(tab: "requests"),
          icon: "hero-globe-americas",
          priority: "high"
        }
      end,
      if chat_unread_count > 0 do
        %{
          id: "chat_unread",
          title: "Catch up on chat",
          detail: "#{chat_unread_count} unread chat message(s)",
          href: Elektrine.Paths.chat_root_path(),
          icon: "hero-chat-bubble-left-right",
          priority: "medium"
        }
      end,
      if Modules.enabled?(:vpn) and vpn_config_count == 0 do
        %{
          id: "vpn_setup",
          title: "Create your first VPN config",
          detail: "Protect your traffic before browsing",
          href: Elektrine.Paths.vpn_path(),
          icon: "hero-shield-check",
          priority: "low"
        }
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  def alerts(
        inbox_unread_count,
        notifications_unread_count,
        chat_unread_count,
        pending_follow_requests_count
      ) do
    [
      if pending_follow_requests_count > 0 do
        %{
          id: "fediverse_follow_requests",
          title: "Pending fediverse follow approvals",
          detail: "#{pending_follow_requests_count} request(s) are waiting",
          href: Elektrine.Paths.friends_path(tab: "requests"),
          icon: "hero-globe-americas",
          level: "high"
        }
      end,
      if notifications_unread_count >= 15 do
        %{
          id: "notification_backlog",
          title: "Notification backlog building up",
          detail: "#{notifications_unread_count} unread notifications",
          href: Elektrine.Paths.notifications_path(),
          icon: "hero-bell-alert",
          level: "medium"
        }
      end,
      if inbox_unread_count >= 25 do
        %{
          id: "inbox_backlog",
          title: "Inbox backlog is growing",
          detail: "#{inbox_unread_count} unread inbox messages",
          href: Elektrine.Paths.email_index_path(tab: "inbox", filter: "unread"),
          icon: "hero-envelope",
          level: "medium"
        }
      end,
      if chat_unread_count >= 20 do
        %{
          id: "chat_backlog",
          title: "Chat backlog is growing",
          detail: "#{chat_unread_count} unread chat messages",
          href: Elektrine.Paths.chat_root_path(),
          icon: "hero-chat-bubble-left-right",
          level: "low"
        }
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp module_available?(user, platform_module, access_module) do
    Modules.enabled?(platform_module) and
      Elektrine.System.user_can_access_module?(user, access_module)
  end
end
