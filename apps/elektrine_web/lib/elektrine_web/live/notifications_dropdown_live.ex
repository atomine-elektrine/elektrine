defmodule ElektrineWeb.NotificationsDropdownLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Notifications
  alias ElektrineWeb.Platform.Integrations
  use Gettext, backend: ElektrineWeb.Gettext

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}
  on_mount {ElektrineWeb.Live.Hooks.NotificationCountHook, :default}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative inline-block" id="notification-dropdown" phx-hook="NotificationDropdown">
      <div class="indicator">
        <%= if @unread_count > 0 do %>
          <span class="indicator-item badge badge-secondary badge-xs">
            {if @unread_count > 99, do: "99+", else: @unread_count}
          </span>
        <% end %>
        <button
          phx-click="toggle_dropdown"
          class={[
            "btn btn-circle btn-sm border hover:bg-base-200",
            if(@unread_count > 0,
              do: "border-secondary/40 bg-secondary/10 text-secondary",
              else: "border-base-300 bg-base-100"
            )
          ]}
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
        <.floating_panel
          class="fixed right-0 mt-2 z-[10000] rounded-box w-full sm:w-[28rem] max-w-md max-h-[80vh] sm:max-h-[640px] flex flex-col overflow-hidden"
          data-notification-dropdown-panel
        >
          <div class="p-3 sm:p-4 border-b border-base-300 flex-shrink-0 bg-base-100/95">
            <div class="flex items-center justify-between gap-2">
              <div>
                <h3 class="font-semibold text-base sm:text-lg">{gettext("Notifications")}</h3>
                <p class="text-xs text-base-content/60">
                  <%= if @unread_count > 0 do %>
                    {gettext("%{count} unread", count: @unread_count)}
                  <% else %>
                    {gettext("You're caught up")}
                  <% end %>
                </p>
              </div>
              <div class="flex items-center gap-1 sm:gap-2">
                <%= if @unread_count > 0 do %>
                  <button
                    phx-click="mark_all_as_read"
                    class="btn btn-xs btn-secondary rounded-full"
                    title={gettext("Mark all read")}
                  >
                    <.icon name="hero-check-circle" class="w-4 h-4 sm:mr-1" />
                    <span class="hidden sm:inline text-xs">{gettext("Mark all read")}</span>
                  </button>
                <% end %>
                <button
                  phx-click="close_dropdown"
                  class="btn btn-circle btn-xs border border-base-300 bg-base-100 hover:bg-base-200"
                  aria-label={gettext("Close notifications")}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            </div>
          </div>

          <div class="overflow-y-auto flex-1">
            <%= if @notifications == [] do %>
              <div class="p-8 text-center text-base-content/60">
                <div class="mx-auto mb-3 flex h-12 w-12 items-center justify-center rounded-full bg-base-200">
                  <.icon name="hero-bell-slash" class="w-6 h-6" />
                </div>
                <p class="font-medium text-base-content">{gettext("No notifications")}</p>
                <p class="mt-1 text-xs">{gettext("New activity will appear here.")}</p>
              </div>
            <% else %>
              <div class="space-y-2 p-2">
                <%= for notification <- @notifications do %>
                  <article class={[
                    "rounded-2xl border p-3 transition-colors hover:bg-base-200 group",
                    if(is_nil(notification.read_at),
                      do: "border-secondary/40 bg-secondary/5",
                      else: "border-base-300 bg-base-100"
                    )
                  ]}>
                    <div class="flex gap-3">
                      <div class="flex-shrink-0 mt-0.5">
                        <div class={[
                          "w-9 h-9 rounded-2xl flex items-center justify-center border",
                          if(notification.priority == "urgent",
                            do: "border-error/30 bg-error/15",
                            else: "border-base-300 bg-base-200"
                          )
                        ]}>
                          <.icon
                            name={notification_icon(notification.type)}
                            class={"w-4 h-4 #{notification_color(notification.priority)}"}
                          />
                        </div>
                      </div>
                      <div class="flex-1 min-w-0">
                        <div class="flex items-start gap-2">
                          <div class="flex-1 min-w-0">
                            <%= if notification.actor do %>
                              <p class="font-medium text-xs text-base-content/70 truncate">
                                <%= if notification.type in ["follow", "mention", "like", "comment", "discussion_reply", "reply"] do %>
                                  @{notification.actor.handle || notification.actor.username}
                                <% else %>
                                  {notification.actor.username}
                                <% end %>
                              </p>
                            <% end %>
                            <button
                              phx-click="view_notification"
                              phx-value-id={notification.id}
                              phx-value-url={notification.url}
                              class={[
                                "mt-0.5 block w-full text-left text-sm leading-5 hover:underline",
                                if(is_nil(notification.read_at),
                                  do: "font-semibold",
                                  else: "font-medium"
                                )
                              ]}
                            >
                              {notification.title}
                            </button>
                            <%= if notification.body do %>
                              <p class="text-xs text-base-content/70 mt-1 line-clamp-2">
                                {notification.body}
                              </p>
                            <% end %>
                            <p class="text-xs text-base-content/60 mt-1 flex items-center gap-2">
                              <%= if is_nil(notification.read_at) do %>
                                <span class="h-2 w-2 rounded-full bg-secondary" aria-hidden="true">
                                </span>
                              <% end %>
                              {time_ago(notification.inserted_at)}
                            </p>
                          </div>
                          <div class="flex flex-col gap-1 sm:opacity-0 sm:group-hover:opacity-100 transition-opacity flex-shrink-0">
                            <%= if is_nil(notification.read_at) do %>
                              <button
                                phx-click="mark_as_read"
                                phx-value-id={notification.id}
                                class="btn btn-circle btn-xs min-h-0 h-7 w-7 border border-base-300 bg-base-100 hover:bg-base-200"
                                title={gettext("Mark as read")}
                              >
                                <.icon name="hero-check" class="w-3 h-3 sm:w-3.5 sm:h-3.5" />
                              </button>
                            <% end %>
                            <button
                              phx-click="dismiss"
                              phx-value-id={notification.id}
                              class="btn btn-circle btn-xs min-h-0 h-7 w-7 border border-base-300 bg-base-100 hover:bg-base-200"
                              title={gettext("Dismiss")}
                            >
                              <.icon name="hero-x-mark" class="w-3 h-3 sm:w-3.5 sm:h-3.5" />
                            </button>
                          </div>
                        </div>
                      </div>
                    </div>
                  </article>
                <% end %>
              </div>
            <% end %>
          </div>

          <%= if @notifications != [] do %>
            <div class="p-2 sm:p-3 border-t border-base-300 flex-shrink-0 bg-base-100/95">
              <button
                phx-click="view_all"
                class="btn btn-sm btn-block rounded-full border border-base-300 bg-base-100 hover:bg-base-200"
              >
                {gettext("Open notification center")}
              </button>
            </div>
          <% end %>
        </.floating_panel>
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
    {:noreply, push_navigate(socket, to: Elektrine.Paths.notifications_path())}
  end

  def handle_event("view_notification", %{"id" => notification_id, "url" => url}, socket) do
    notification_id = String.to_integer(notification_id)
    Notifications.mark_as_read(notification_id, socket.assigns.current_user.id)

    socket =
      socket
      |> assign(:dropdown_open, false)
      |> load_notifications()
      |> push_event("dropdown_closed", %{})

    if present_url?(url) do
      {:noreply, push_navigate(socket, to: url)}
    else
      {:noreply, socket}
    end
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

  defp present_url?(url) when is_binary(url), do: String.trim(url) != ""
  defp present_url?(_url), do: false

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
    Integrations.social_time_ago(datetime)
  end
end
