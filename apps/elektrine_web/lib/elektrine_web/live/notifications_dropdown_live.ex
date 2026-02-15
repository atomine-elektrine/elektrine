defmodule ElektrineWeb.NotificationsDropdownLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Notifications
  use Gettext, backend: ElektrineWeb.Gettext

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}
  on_mount {ElektrineWeb.Live.Hooks.NotificationCountHook, :default}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative inline-block" id="notification-dropdown" phx-hook="NotificationDropdown">
      <div class="indicator">
        <%= if @unread_count > 0 do %>
          <span class="indicator-item badge badge-primary badge-xs">
            {if @unread_count > 99, do: "99+", else: @unread_count}
          </span>
        <% end %>
        <button
          phx-click="toggle_dropdown"
          class="btn btn-ghost btn-circle btn-sm"
          aria-label={gettext("Notifications")}
        >
          <%= if @unread_count > 0 do %>
            <.icon name="hero-bell-alert" class="w-5 h-5" />
          <% else %>
            <.icon name="hero-bell" class="w-5 h-5" />
          <% end %>
        </button>
      </div>

      <%= if @dropdown_open do %>
        <div class="fixed sm:absolute right-0 sm:right-0 mt-2 z-50 bg-base-100 rounded-box w-full sm:w-96 max-w-md shadow-2xl border border-base-300 max-h-[80vh] sm:max-h-[600px] flex flex-col">
          <div class="p-3 sm:p-4 border-b border-base-300 flex-shrink-0">
            <div class="flex items-center justify-between gap-2">
              <h3 class="font-semibold text-base sm:text-lg">{gettext("Notifications")}</h3>
              <div class="flex items-center gap-1 sm:gap-2">
                <%= if @unread_count > 0 do %>
                  <button
                    phx-click="mark_all_as_read"
                    class="btn btn-ghost btn-xs"
                    title={gettext("Mark all read")}
                  >
                    <.icon name="hero-check-circle" class="w-4 h-4 sm:mr-1" />
                    <span class="hidden sm:inline text-xs">{gettext("Mark all read")}</span>
                  </button>
                <% end %>
                <button
                  phx-click="close_dropdown"
                  class="btn btn-ghost btn-circle btn-xs"
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            </div>
          </div>

          <div class="overflow-y-auto flex-1">
            <%= if @notifications == [] do %>
              <div class="p-8 text-center text-base-content/60">
                <.icon name="hero-bell-slash" class="w-12 h-12 mx-auto mb-3" />
                <p>{gettext("No notifications")}</p>
              </div>
            <% else %>
              <div class="divide-y divide-base-200">
                <%= for notification <- @notifications do %>
                  <div class={"p-2 sm:p-3 hover:bg-base-200/50 active:bg-base-300 transition-colors relative group #{if is_nil(notification.read_at), do: "bg-primary/5"}"}>
                    <div class="flex gap-2 sm:gap-3">
                      <div class="flex-shrink-0 mt-0.5 sm:mt-1">
                        <div class={"w-7 h-7 sm:w-8 sm:h-8 rounded-full flex items-center justify-center #{if notification.priority == "urgent", do: "bg-error/20", else: "bg-base-300"}"}>
                          <.icon
                            name={notification_icon(notification.type)}
                            class={"w-3.5 h-3.5 sm:w-4 sm:h-4 #{notification_color(notification.priority)}"}
                          />
                        </div>
                      </div>
                      <div class="flex-1 min-w-0">
                        <div class="flex items-start gap-2">
                          <div class="flex-1 min-w-0">
                            <%= if notification.actor do %>
                              <p class="font-medium text-xs sm:text-sm truncate">
                                <%= if notification.type in ["follow", "mention", "like", "comment", "discussion_reply", "reply"] do %>
                                  @{notification.actor.handle || notification.actor.username}
                                <% else %>
                                  {notification.actor.username}
                                <% end %>
                              </p>
                            <% end %>
                            <p class="text-xs sm:text-sm text-base-content/80 line-clamp-2">
                              {notification.title}
                            </p>
                            <%= if notification.body do %>
                              <p class="text-xs text-base-content/70 mt-1 line-clamp-1 sm:line-clamp-2">
                                {notification.body}
                              </p>
                            <% end %>
                            <p class="text-xs text-base-content/60 mt-1">
                              {time_ago(notification.inserted_at)}
                            </p>
                            <%= if notification.url do %>
                              <a
                                href={notification.url}
                                class="inline-block mt-1 sm:mt-2 text-xs text-primary hover:underline"
                              >
                                {gettext("View")} →
                              </a>
                            <% end %>
                          </div>
                          <div class="flex flex-col gap-1 sm:opacity-0 sm:group-hover:opacity-100 transition-opacity flex-shrink-0">
                            <%= if is_nil(notification.read_at) do %>
                              <button
                                phx-click="mark_as_read"
                                phx-value-id={notification.id}
                                class="btn btn-ghost btn-circle btn-xs min-h-0 h-7 w-7"
                                title={gettext("Mark as read")}
                              >
                                <.icon name="hero-check" class="w-3 h-3 sm:w-3.5 sm:h-3.5" />
                              </button>
                            <% end %>
                            <button
                              phx-click="dismiss"
                              phx-value-id={notification.id}
                              class="btn btn-ghost btn-circle btn-xs min-h-0 h-7 w-7"
                              title={gettext("Dismiss")}
                            >
                              <.icon name="hero-x-mark" class="w-3 h-3 sm:w-3.5 sm:h-3.5" />
                            </button>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%= if @notifications != [] do %>
            <div class="p-2 sm:p-3 border-t border-base-300 flex-shrink-0">
              <button
                phx-click="view_all"
                class="btn btn-ghost btn-sm btn-block text-xs sm:text-sm"
              >
                {gettext("View all notifications")}
              </button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    # Get user from session
    user_id = session["user_id"]

    if user_id do
      user = Elektrine.Accounts.get_user!(user_id)

      # Set locale from session or user preference
      locale = session["locale"] || user.locale || "en"
      Gettext.put_locale(ElektrineWeb.Gettext, locale)

      if connected?(socket) do
        # Subscribe to notification updates
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}:notifications")
      end

      {:ok,
       socket
       |> assign(:current_user, user)
       |> assign(:notifications, [])
       |> assign(:unread_count, 0)
       |> assign(:dropdown_open, false)
       |> assign(:loading, false)
       |> assign(:locale, locale)
       |> load_notifications()}
    else
      # No user, return empty state
      {:ok,
       socket
       |> assign(:current_user, nil)
       |> assign(:notifications, [])
       |> assign(:unread_count, 0)
       |> assign(:dropdown_open, false)
       |> assign(:loading, false)
       |> assign(:locale, session["locale"] || "en")}
    end
  end

  @impl true
  def handle_event("toggle_dropdown", _params, socket) do
    socket =
      if socket.assigns.dropdown_open do
        # Closing dropdown
        socket
        |> assign(:dropdown_open, false)
        |> push_event("dropdown_closed", %{})
      else
        # Opening dropdown - load fresh notifications and mark as seen
        socket =
          socket
          |> assign(:dropdown_open, true)
          |> load_notifications()
          |> push_event("dropdown_opened", %{})

        # Mark visible notifications as seen
        visible_ids =
          socket.assigns.notifications
          |> Enum.take(10)
          |> Enum.map(& &1.id)

        if visible_ids != [] do
          Notifications.mark_as_seen(visible_ids, socket.assigns.current_user.id)
        end

        socket
      end

    {:noreply, socket}
  end

  def handle_event("mark_as_read", %{"id" => notification_id}, socket) do
    notification_id = String.to_integer(notification_id)
    Notifications.mark_as_read(notification_id, socket.assigns.current_user.id)

    # Update the notification in the list
    notifications =
      Enum.map(socket.assigns.notifications, fn n ->
        if n.id == notification_id do
          %{n | read_at: DateTime.utc_now(), seen_at: DateTime.utc_now()}
        else
          n
        end
      end)

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> update(:unread_count, &max(&1 - 1, 0))}
  end

  def handle_event("mark_all_as_read", _params, socket) do
    Notifications.mark_all_as_read(socket.assigns.current_user.id)

    # Update all notifications in the list
    notifications =
      Enum.map(socket.assigns.notifications, fn n ->
        %{n | read_at: DateTime.utc_now(), seen_at: DateTime.utc_now()}
      end)

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> assign(:unread_count, 0)}
  end

  def handle_event("dismiss", %{"id" => notification_id}, socket) do
    notification_id = String.to_integer(notification_id)
    Notifications.dismiss_notification(notification_id, socket.assigns.current_user.id)

    # Remove from the list
    notifications = Enum.reject(socket.assigns.notifications, &(&1.id == notification_id))

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> update(:unread_count, fn count ->
       dismissed_was_unread =
         Enum.any?(socket.assigns.notifications, fn n ->
           n.id == notification_id && is_nil(n.read_at)
         end)

       if dismissed_was_unread, do: max(count - 1, 0), else: count
     end)}
  end

  def handle_event("close_dropdown", _params, socket) do
    {:noreply,
     socket
     |> assign(:dropdown_open, false)
     |> push_event("dropdown_closed", %{})}
  end

  def handle_event("view_all", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/notifications")}
  end

  @impl true
  def handle_info({:new_notification, notification}, socket) do
    # Prepend new notification to the list
    notification = Elektrine.Repo.preload(notification, [:actor])

    {:noreply,
     socket
     # Keep max 20 in dropdown
     |> update(:notifications, &[notification | Enum.take(&1, 19)])
     |> update(:unread_count, &(&1 + 1))}
  end

  def handle_info(:notification_updated, socket) do
    # Refresh counts
    {:noreply, load_notifications(socket)}
  end

  def handle_info(:all_notifications_read, socket) do
    # Update all notifications as read
    notifications =
      Enum.map(socket.assigns.notifications, fn n ->
        %{n | read_at: DateTime.utc_now(), seen_at: DateTime.utc_now()}
      end)

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> assign(:unread_count, 0)}
  end

  # Private functions
  defp load_notifications(socket) do
    if socket.assigns.current_user do
      notifications = Notifications.list_notifications(socket.assigns.current_user.id, limit: 20)
      unread_count = Notifications.get_unread_count(socket.assigns.current_user.id)

      socket
      |> assign(:notifications, notifications)
      |> assign(:unread_count, unread_count)
    else
      socket
    end
  end

  defp notification_icon(type) do
    case type do
      "new_message" -> "hero-chat-bubble-left"
      "mention" -> "hero-at-symbol"
      "reply" -> "hero-chat-bubble-left-right"
      "follow" -> "hero-user-plus"
      "like" -> "hero-heart"
      "comment" -> "hero-chat-bubble-bottom-center"
      "discussion_reply" -> "hero-chat-bubble-bottom-center-text"
      "email_received" -> "hero-envelope"
      "system" -> "hero-information-circle"
      _ -> "hero-bell"
    end
  end

  defp notification_color(priority) do
    case priority do
      "urgent" -> "text-error"
      "high" -> "text-warning"
      "low" -> "text-base-content/60"
      _ -> "text-base-content"
    end
  end

  defp time_ago(datetime) do
    Elektrine.Social.time_ago_in_words(datetime)
  end
end
