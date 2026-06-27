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

  defp module_available?(user, platform_module, access_module) do
    Modules.enabled?(platform_module) and
      Elektrine.System.user_can_access_module?(user, access_module)
  end
end
