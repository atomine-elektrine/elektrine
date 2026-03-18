defmodule ElektrineWeb.NotificationsLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Notifications
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.User.Avatar

  @state_filters %{"all" => :all, "unread" => :unread, "unseen" => :unseen}
  @source_filters ~w(all chat email requests social system)

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    # Set locale from session or user preference
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    # Load cached unread count to prevent badge flicker on refresh
    {:ok, cached_unread} =
      Elektrine.AppCache.get_notification_unread_count(user.id, fn ->
        Notifications.get_unread_count(user.id)
      end)

    if connected?(socket) do
      # Subscribe to notification updates
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}:notifications")
      # Load notifications asynchronously after connection
      send(self(), :load_notifications)
    end

    {:ok,
     socket
     |> assign(:page_title, "Notifications")
     |> assign(:loading_notifications, true)
     # Initialize with cached unread count to prevent flicker
     |> assign(:grouped_notifications, [])
     |> assign(:filtered_notifications, [])
     |> assign(:expanded_groups, MapSet.new())
     |> assign(:unread_count, cached_unread)
     |> assign(:unseen_count, 0)
     |> assign(:filter, :all)
     |> assign(:source_filter, "all")
     |> assign(:notification_stats, default_notification_stats())
     |> assign(:loading_more, false)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filter = parse_state_filter(params["filter"])
    source_filter = parse_source_filter(params["source"])

    socket =
      socket
      |> assign(:filter, filter)
      |> assign(:source_filter, source_filter)

    # Only load data synchronously if we're connected and not in initial loading state
    # The initial load is handled by send(self(), :load_notifications) in mount
    if connected?(socket) && !socket.assigns.loading_notifications do
      {:noreply, reload_notification_data(socket)}
    else
      # Trigger async load for filter change when connected
      if connected?(socket) do
        send(self(), :load_notifications)
      end

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("mark_as_read", %{"id" => notification_id}, socket) do
    notification_id = String.to_integer(notification_id)
    Notifications.mark_as_read(notification_id, socket.assigns.current_user.id)

    {:noreply, reload_notification_data(socket)}
  end

  def handle_event("mark_visible_as_read", %{"notification_ids" => notification_ids}, socket) do
    user_id = socket.assigns.current_user.id

    notification_ids
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case Integer.parse(to_string(id)) do
        {parsed_id, ""} -> [parsed_id]
        _ -> []
      end
    end)
    |> Enum.each(&Notifications.mark_as_read(&1, user_id))

    {:noreply, reload_notification_data(socket)}
  end

  def handle_event("mark_all_as_read", _params, socket) do
    Notifications.mark_all_as_read(socket.assigns.current_user.id)

    {:noreply, reload_notification_data(socket)}
  end

  def handle_event("dismiss", %{"id" => notification_id}, socket) do
    notification_id = String.to_integer(notification_id)
    Notifications.dismiss_notification(notification_id, socket.assigns.current_user.id)

    {:noreply, reload_notification_data(socket)}
  end

  def handle_event("dismiss_all", _params, socket) do
    Notifications.dismiss_all_notifications(socket.assigns.current_user.id)

    {:noreply, reload_notification_data(socket)}
  end

  def handle_event("set_filter", %{"type" => filter_type}, socket) do
    filter = parse_state_filter(filter_type)

    {:noreply,
     push_patch(
       socket,
       to:
         ~p"/notifications?#{[filter: state_filter_param(filter), source: socket.assigns.source_filter]}"
     )}
  end

  def handle_event("set_source_filter", %{"source" => source_filter}, socket) do
    source_filter = parse_source_filter(source_filter)

    {:noreply,
     push_patch(
       socket,
       to:
         ~p"/notifications?#{[filter: state_filter_param(socket.assigns.filter), source: source_filter]}"
     )}
  end

  def handle_event("toggle_group", %{"group_key" => group_key}, socket) do
    expanded_groups = socket.assigns.expanded_groups

    new_expanded =
      if MapSet.member?(expanded_groups, group_key) do
        MapSet.delete(expanded_groups, group_key)
      else
        MapSet.put(expanded_groups, group_key)
      end

    {:noreply, assign(socket, :expanded_groups, new_expanded)}
  end

  def handle_event("mark_group_as_read", %{"group_key" => group_key}, socket) do
    group = find_group_by_key(socket.assigns.grouped_notifications, group_key)

    if group do
      user_id = socket.assigns.current_user.id

      Enum.each(notification_ids_for_group(group), &Notifications.mark_as_read(&1, user_id))

      {:noreply, reload_notification_data(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("view_notification", %{"id" => notification_id, "url" => url}, socket) do
    # Mark as read when clicking on a notification
    notification_id = String.to_integer(notification_id)
    Notifications.mark_as_read(notification_id, socket.assigns.current_user.id)

    socket = reload_notification_data(socket)

    if is_binary(url) and url != "" do
      {:noreply, push_navigate(socket, to: url)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:load_notifications, socket) do
    user = socket.assigns.current_user
    filter = socket.assigns.filter

    # Load notifications data in parallel
    notifications_task =
      Task.async(fn ->
        Notifications.list_grouped_notifications(user.id, filter: filter)
      end)

    unread_task = Task.async(fn -> Notifications.get_unread_count(user.id) end)
    unseen_task = Task.async(fn -> Notifications.get_unseen_count(user.id) end)

    grouped_notifications = Task.await(notifications_task)
    unread_count = Task.await(unread_task)
    unseen_count = Task.await(unseen_task)

    {:noreply,
     socket
     |> assign(:loading_notifications, false)
     |> assign_notification_data(grouped_notifications, unread_count, unseen_count)}
  end

  @impl true
  def handle_info({:new_notification, _notification}, socket) do
    {:noreply, reload_notification_data(socket)}
  end

  def handle_info(:notification_updated, socket) do
    {:noreply, reload_notification_data(socket)}
  end

  def handle_info(:all_notifications_read, socket) do
    {:noreply, reload_notification_data(socket)}
  end

  def handle_info(:all_notifications_dismissed, socket) do
    {:noreply, reload_notification_data(socket)}
  end

  def handle_info(:notification_dismissed, socket) do
    {:noreply, reload_notification_data(socket)}
  end

  def handle_info(:notifications_seen, socket) do
    {:noreply, reload_notification_data(socket)}
  end

  def handle_info(_message, socket) do
    # Ignore other messages we don't handle
    {:noreply, socket}
  end

  defp reload_notification_data(socket) do
    user_id = socket.assigns.current_user.id

    grouped_notifications =
      Notifications.list_grouped_notifications(user_id, filter: socket.assigns.filter)

    unread_count = Notifications.get_unread_count(user_id)
    unseen_count = Notifications.get_unseen_count(user_id)

    assign_notification_data(socket, grouped_notifications, unread_count, unseen_count)
  end

  defp assign_notification_data(socket, grouped_notifications, unread_count, unseen_count) do
    enriched_groups = Enum.map(grouped_notifications, &decorate_group/1)

    socket
    |> assign(:grouped_notifications, enriched_groups)
    |> assign(
      :filtered_notifications,
      filter_groups(enriched_groups, socket.assigns.source_filter)
    )
    |> assign(:unread_count, unread_count)
    |> assign(:unseen_count, unseen_count)
    |> assign(
      :notification_stats,
      build_notification_stats(enriched_groups, unread_count, unseen_count)
    )
  end

  defp decorate_group(group) do
    latest_notification = latest_notification_for_group(group)
    source = notification_source_for_group(group)

    group
    |> Map.put(:group_key, notification_group_key(group))
    |> Map.put(:source, source)
    |> Map.put(:title, notification_group_title(group))
    |> Map.put(:detail, notification_group_detail(group))
    |> Map.put(:icon_name, notification_icon_for_group(group))
    |> Map.put(:destination, notification_destination_for_group(group))
    |> Map.put(:unread_count, unread_count_for_group(group))
    |> Map.put(:notification_ids, notification_ids_for_group(group))
    |> Map.put(:unread_notification_ids, unread_notification_ids_for_group(group))
    |> Map.put(:latest_notification, latest_notification)
    |> Map.put(:priority, (latest_notification && latest_notification.priority) || "normal")
  end

  defp filter_groups(groups, "all"), do: groups

  defp filter_groups(groups, source_filter),
    do: Enum.filter(groups, &(&1.source == source_filter))

  defp build_notification_stats(groups, unread_count, unseen_count) do
    source_counts =
      Enum.reduce(@source_filters, %{}, fn source, acc ->
        Map.put(acc, source, 0)
      end)

    source_counts =
      Enum.reduce(groups, source_counts, fn group, acc ->
        Map.update(acc, group.source, 1, &(&1 + 1))
      end)

    %{
      total_groups: length(groups),
      unread: unread_count,
      unseen: unseen_count,
      waiting_groups: Enum.count(groups, &(&1.unread_count > 0)),
      source_counts: Map.put(source_counts, "all", length(groups))
    }
  end

  defp default_notification_stats do
    %{
      total_groups: 0,
      unread: 0,
      unseen: 0,
      waiting_groups: 0,
      source_counts:
        Enum.reduce(@source_filters, %{}, fn source, acc ->
          Map.put(acc, source, 0)
        end)
        |> Map.put("all", 0)
    }
  end

  defp parse_state_filter(filter), do: Map.get(@state_filters, filter || "all", :all)
  defp parse_source_filter(source) when source in @source_filters, do: source
  defp parse_source_filter(_source), do: "all"

  defp state_filter_param(filter) do
    Enum.find_value(@state_filters, "all", fn {param, value} ->
      if value == filter, do: param, else: nil
    end)
  end

  defp notification_group_key(%{type: :chat_group, conversation_id: conversation_id}) do
    "chat-#{conversation_id}"
  end

  defp notification_group_key(%{type: :email_group, sender: %{id: sender_id}}) do
    "email-#{sender_id}"
  end

  defp notification_group_key(%{type: :email_group, latest_notification: notification}) do
    "email-#{notification.id}"
  end

  defp notification_group_key(%{type: :single, notification: notification}) do
    "single-#{notification.id}"
  end

  defp latest_notification_for_group(%{type: :single, notification: notification}),
    do: notification

  defp latest_notification_for_group(group), do: group.latest_notification

  defp notification_source_for_group(%{type: :chat_group}), do: "chat"
  defp notification_source_for_group(%{type: :email_group}), do: "email"

  defp notification_source_for_group(%{type: :single, notification: notification}) do
    case {notification.type, notification.source_type} do
      {"new_message", _} -> "chat"
      {"reply", "message"} -> "chat"
      {"email_received", _} -> "email"
      {"follow", _} -> "requests"
      {"mention", _} -> "social"
      {"reply", _} -> "social"
      {"like", _} -> "social"
      {"comment", _} -> "social"
      {"discussion_reply", _} -> "social"
      _ -> "system"
    end
  end

  defp notification_group_title(%{type: :chat_group, conversation_name: conversation_name}) do
    conversation_name
  end

  defp notification_group_title(%{type: :email_group, sender: %{handle: handle}})
       when is_binary(handle) and handle != "" do
    "Email from @#{handle}"
  end

  defp notification_group_title(%{type: :email_group}) do
    "Email"
  end

  defp notification_group_title(%{type: :single, notification: notification}) do
    single_notification_title(notification)
  end

  defp notification_group_detail(%{type: :chat_group, latest_notification: notification}) do
    notification.body || "New chat activity"
  end

  defp notification_group_detail(%{type: :email_group, latest_notification: notification}) do
    notification.body || "New email activity"
  end

  defp notification_group_detail(%{type: :single, notification: notification}) do
    body = normalize_notification_text(notification.body)
    title = normalize_notification_text(single_notification_title(notification))

    if is_nil(body) or body == title do
      nil
    else
      body
    end
  end

  defp notification_icon_for_group(%{type: :chat_group}), do: "hero-chat-bubble-left-right"
  defp notification_icon_for_group(%{type: :email_group}), do: "hero-envelope"

  defp notification_icon_for_group(%{type: :single, notification: notification}) do
    notification.icon || notification_icon(notification.type)
  end

  defp notification_destination_for_group(%{type: :single, notification: notification}) do
    notification.url ||
      default_source_path(
        notification_source_for_group(%{type: :single, notification: notification})
      )
  end

  defp notification_destination_for_group(group) do
    latest_notification = latest_notification_for_group(group)
    latest_notification.url || default_source_path(notification_source_for_group(group))
  end

  defp unread_count_for_group(%{type: :single, notification: notification}) do
    if is_nil(notification.read_at), do: 1, else: 0
  end

  defp unread_count_for_group(group), do: group.unread_count

  defp notification_ids_for_group(%{type: :single, notification: notification}),
    do: [notification.id]

  defp notification_ids_for_group(group), do: Enum.map(group.notifications, & &1.id)

  defp unread_notification_ids_for_group(%{type: :single, notification: notification}) do
    if is_nil(notification.read_at), do: [notification.id], else: []
  end

  defp unread_notification_ids_for_group(group) do
    group.notifications
    |> Enum.filter(&is_nil(&1.read_at))
    |> Enum.map(& &1.id)
  end

  defp find_group_by_key(groups, group_key), do: Enum.find(groups, &(&1.group_key == group_key))

  defp default_source_path("chat"), do: ~p"/chat"
  defp default_source_path("email"), do: ~p"/email?tab=inbox&filter=unread"
  defp default_source_path("requests"), do: ~p"/friends?tab=requests"
  defp default_source_path("social"), do: ~p"/timeline"
  defp default_source_path(_source), do: ~p"/overview"

  defp notification_source_label("all"), do: "All"
  defp notification_source_label("chat"), do: "Chat"
  defp notification_source_label("email"), do: "Email"
  defp notification_source_label("requests"), do: "Requests"
  defp notification_source_label("social"), do: "Social"
  defp notification_source_label("system"), do: "System"
  defp notification_source_label(source), do: String.capitalize(source)

  defp notification_state_label(:all), do: "All"
  defp notification_state_label(:unread), do: "Unread"
  defp notification_state_label(:unseen), do: "Unseen"

  defp notification_state_count(:all, stats), do: stats.total_groups
  defp notification_state_count(:unread, stats), do: stats.waiting_groups
  defp notification_state_count(:unseen, stats), do: stats.unseen

  defp state_filter_button_class(current_filter, filter) do
    [
      "btn btn-sm",
      if(current_filter == filter, do: "btn-secondary", else: "btn-ghost")
    ]
  end

  defp notification_source_badge_class("chat"), do: "badge badge-primary badge-xs"
  defp notification_source_badge_class("email"), do: "badge badge-info badge-xs"
  defp notification_source_badge_class("requests"), do: "badge badge-warning badge-xs"
  defp notification_source_badge_class("social"), do: "badge badge-secondary badge-xs"
  defp notification_source_badge_class(_source), do: "badge badge-ghost badge-xs"

  defp notification_state_badge_class(0), do: "badge badge-ghost badge-xs"
  defp notification_state_badge_class(_count), do: "badge badge-primary badge-xs"

  defp notification_priority_badge_class("urgent"), do: "badge badge-error badge-xs"
  defp notification_priority_badge_class("high"), do: "badge badge-warning badge-xs"
  defp notification_priority_badge_class("low"), do: "badge badge-ghost badge-xs"
  defp notification_priority_badge_class(_priority), do: "badge badge-neutral badge-xs"

  defp group_card_class(group) do
    [
      "rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm transition-colors",
      if(group.unread_count > 0,
        do: "border-l-4 border-l-primary hover:bg-base-200/40",
        else: "hover:bg-base-200/20"
      )
    ]
  end

  defp source_filter_button_class(current_filter, filter) do
    [
      "btn btn-xs",
      if(current_filter == filter, do: "btn-secondary", else: "btn-ghost")
    ]
  end

  defp single_notification_title(%{type: "follow"} = notification) do
    title = normalize_notification_text(notification.title)
    body = normalize_notification_text(notification.body)

    cond do
      title in ["New follower from the fediverse", "Follow request accepted"] and not is_nil(body) ->
        body

      not is_nil(title) ->
        title

      not is_nil(body) ->
        body

      true ->
        "Notification"
    end
  end

  defp single_notification_title(notification) do
    normalize_notification_text(notification.title) ||
      normalize_notification_text(notification.body) ||
      "Notification"
  end

  defp normalize_notification_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_notification_text(_), do: nil

  # Helper functions
  defp notification_icon(type) do
    case type do
      "new_message" -> "hero-chat-bubble-left-right"
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
end
