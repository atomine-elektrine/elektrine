defmodule Elektrine.Notifications do
  @moduledoc """
  The Notifications context.
  """

  require Logger

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.{UserBlock, UserMute}
  alias Elektrine.Messaging
  alias Elektrine.Notifications.Notification
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Telemetry.Events

  @doc """
  Creates a notification.
  """
  def create_notification(attrs \\ %{}) do
    started_at = System.monotonic_time(:millisecond)

    notification =
      %Notification{}
      |> Notification.changeset(attrs)
      |> Repo.insert()

    case notification do
      {:ok, notif} ->
        # Invalidate notification cache
        Elektrine.AppCache.invalidate_notification_cache(notif.user_id)

        # Broadcast to user's notification channel
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{notif.user_id}:notifications",
          {:new_notification, notif}
        )

        # Also broadcast count update
        new_count = get_unread_count(notif.user_id)

        Events.db_hot_path(
          :notifications,
          :create_notification,
          System.monotonic_time(:millisecond) - started_at,
          %{user_id: notif.user_id, type: notif.type}
        )

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{notif.user_id}:notification_count",
          {:notification_count_updated, new_count}
        )

        # Send push notification if user is offline
        if Elektrine.Push.should_send_push?(notif.user_id) do
          Elektrine.Push.notify_user(notif.user_id, %{
            title: notif.title,
            body: notif.body,
            badge: new_count,
            data: %{
              type: notif.type,
              url: notif.url,
              source_type: notif.source_type,
              source_id: notif.source_id,
              notification_id: notif.id
            }
          })
        end

        Elektrine.Async.run(fn ->
          maybe_emit_developer_webhook(notif, new_count)
        end)

        {:ok, notif}

      {:error, changeset} = error ->
        Logger.error("Failed to create notification: #{inspect(changeset.errors)}")
        error
    end
  end

  @doc """
  Creates a notification for multiple users.
  """
  def create_bulk_notifications(user_ids, attrs) do
    notifications =
      Enum.map(user_ids, fn user_id ->
        attrs
        |> Map.put(:user_id, user_id)
        |> Map.put(:inserted_at, DateTime.utc_now())
        |> Map.put(:updated_at, DateTime.utc_now())
      end)

    {count, _} = Repo.insert_all(Notification, notifications)
    unique_user_ids = Enum.uniq(user_ids)

    Enum.each(unique_user_ids, &Elektrine.AppCache.invalidate_notification_cache/1)

    # Broadcast to all users
    Enum.each(unique_user_ids, fn user_id ->
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "user:#{user_id}:notifications",
        :notification_created
      )
    end)

    {:ok, count}
  end

  @doc """
  Gets grouped notifications for a user.
  Groups chat messages by conversation, emails by sender.
  """
  def list_grouped_notifications(user_id, opts \\ []) do
    filter = Keyword.get(opts, :filter, :all)
    source_filter = Keyword.get(opts, :source_filter, "all")

    # Get raw notifications
    notifications =
      list_notifications(user_id, filter: filter, source_filter: source_filter, limit: 200)

    # Group notifications
    groups =
      notifications
      |> Enum.group_by(fn n ->
        case n.type do
          type when type in ["new_message", "reply"] and n.source_type == "message" ->
            # Group chat messages by conversation (extract from URL)
            conversation_id = extract_conversation_id(n.url)
            {:chat, conversation_id}

          "email_received" ->
            # Group emails by sender (actor_id)
            {:email, n.actor_id}

          type when type in ["like", "mention", "comment", "discussion_reply", "reply"] ->
            # Group social activity by target source/post so multiple actors collapse into
            # Mastodon-style "X and N others" notification groups.
            {:social, type, n.source_type, n.source_id || n.url || n.id}

          _ ->
            # Don't group other types
            {:single, n.id}
        end
      end)
      |> Enum.flat_map(fn {key, notifs} ->
        case key do
          {:chat, conversation_id} when conversation_id != nil ->
            [build_chat_group(notifs, conversation_id)]

          {:email, actor_id} when actor_id != nil ->
            [build_email_group(notifs)]

          {:social, _type, _source_type, target} when not is_nil(target) ->
            [build_social_group(notifs)]

          {:single, _} ->
            # Single notification (not grouped)
            [
              %{
                type: :single,
                notification: hd(notifs),
                count: 1,
                latest_at: hd(notifs).inserted_at
              }
            ]

          _ ->
            # Handle edge cases (nil conversation_id, nil actor_id, etc)
            # Treat as individual notifications
            Enum.map(notifs, fn n ->
              %{
                type: :single,
                notification: n,
                count: 1,
                latest_at: n.inserted_at
              }
            end)
        end
      end)
      |> Enum.sort_by(& &1.latest_at, :desc)

    groups
  end

  defp extract_conversation_id(url) when is_binary(url) do
    case Regex.run(~r/\/chat\/(\d+)/, url) do
      [_, id] -> String.to_integer(id)
      _ -> nil
    end
  end

  defp extract_conversation_id(_), do: nil

  defp build_chat_group(notifs, conversation_id) do
    sorted = Enum.sort_by(notifs, & &1.inserted_at, :desc)
    latest = hd(sorted)
    unread_count = Enum.count(sorted, &is_nil(&1.read_at))

    # Get conversation name from first notification
    conversation_name =
      case Regex.run(~r/(?:in |from )(.+?)(?:\s*$|"|message)/, latest.title) do
        [_, name] -> name
        _ -> "Arblarg"
      end

    %{
      type: :chat_group,
      conversation_id: conversation_id,
      conversation_name: conversation_name,
      notifications: sorted,
      count: length(sorted),
      unread_count: unread_count,
      latest_at: latest.inserted_at,
      latest_notification: latest,
      actors:
        notifs |> Enum.map(& &1.actor) |> Enum.uniq_by(&(&1 && &1.id)) |> Enum.reject(&is_nil/1)
    }
  end

  defp build_email_group(notifs) do
    sorted = Enum.sort_by(notifs, & &1.inserted_at, :desc)
    latest = hd(sorted)
    unread_count = Enum.count(sorted, &is_nil(&1.read_at))

    %{
      type: :email_group,
      notifications: sorted,
      count: length(sorted),
      unread_count: unread_count,
      latest_at: latest.inserted_at,
      latest_notification: latest,
      sender: latest.actor
    }
  end

  defp build_social_group(notifs) do
    sorted = Enum.sort_by(notifs, & &1.inserted_at, :desc)
    latest = hd(sorted)
    unread_count = Enum.count(sorted, &is_nil(&1.read_at))

    %{
      type: :social_group,
      social_type: latest.type,
      source_type: latest.source_type,
      source_id: latest.source_id,
      notifications: sorted,
      count: length(sorted),
      unread_count: unread_count,
      latest_at: latest.inserted_at,
      latest_notification: latest,
      actors:
        notifs
        |> Enum.map(& &1.actor)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.id)
    }
  end

  @doc """
  Gets notifications for a user.
  """
  def list_notifications(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    filter = Keyword.get(opts, :filter, :all)
    source_filter = Keyword.get(opts, :source_filter, "all")

    query =
      from(n in Notification,
        where: n.user_id == ^user_id and is_nil(n.dismissed_at),
        order_by: [desc: n.inserted_at],
        limit: ^limit,
        offset: ^offset,
        preload: [:actor]
      )

    query =
      case filter do
        :unread -> where(query, [n], is_nil(n.read_at))
        :unseen -> where(query, [n], is_nil(n.seen_at))
        _ -> query
      end

    query = apply_source_filter(query, source_filter)
    query = apply_actor_safety_filter(query, user_id)

    query
    |> Repo.all()
    |> resolve_legacy_message_notification_urls()
  end

  defp apply_actor_safety_filter(query, user_id) do
    from(n in query,
      left_join: mute in UserMute,
      on:
        mute.muter_id == ^user_id and mute.muted_id == n.actor_id and
          mute.mute_notifications == true,
      left_join: block in UserBlock,
      on: block.blocker_id == ^user_id and block.blocked_id == n.actor_id,
      where: is_nil(mute.id) and is_nil(block.id)
    )
  end

  defp apply_source_filter(query, source_filter) do
    case source_filter do
      "chat" ->
        where(
          query,
          [n],
          n.type == "new_message" or (n.type == "reply" and n.source_type == "message")
        )

      "email" ->
        where(query, [n], n.type == "email_received")

      "requests" ->
        where(query, [n], n.type == "follow")

      "social" ->
        where(
          query,
          [n],
          n.type in ["mention", "like", "comment", "discussion_reply"] or
            (n.type == "reply" and n.source_type != "message")
        )

      "system" ->
        where(query, [n], n.type == "system")

      _ ->
        query
    end
  end

  @doc """
  Resolves the canonical navigation URL for a message-backed notification.
  """
  def resolve_message_notification_url(message_id, notification_type \\ nil)

  def resolve_message_notification_url(message_id, notification_type)
      when is_integer(message_id) do
    {messages_by_id, parents_by_id} = load_messages_with_parents([message_id])

    case Map.get(messages_by_id, message_id) do
      %Message{} = message ->
        build_message_notification_url(
          message,
          Map.get(parents_by_id, message.reply_to_id),
          notification_type
        )

      nil ->
        nil
    end
  end

  def resolve_message_notification_url(_, _), do: nil

  @doc """
  Gets unread notification count for a user.
  """
  def get_unread_count(user_id) do
    started_at = System.monotonic_time(:millisecond)

    case Elektrine.AppCache.get_notification_unread_count(user_id, fn ->
           query_unread_count(user_id)
         end) do
      {:ok, count} ->
        Events.db_hot_path(
          :notifications,
          :get_unread_count,
          System.monotonic_time(:millisecond) - started_at,
          %{user_id: user_id, cache: :hit}
        )

        count

      _ ->
        count = query_unread_count(user_id)

        Events.db_hot_path(
          :notifications,
          :get_unread_count,
          System.monotonic_time(:millisecond) - started_at,
          %{user_id: user_id, cache: :miss}
        )

        count
    end
  end

  @doc """
  Gets unseen notification count for a user.
  """
  def get_unseen_count(user_id) do
    from(n in Notification,
      where: n.user_id == ^user_id and is_nil(n.seen_at) and is_nil(n.dismissed_at),
      select: count(n.id)
    )
    |> Repo.one()
  end

  @doc """
  Marks a notification as read.
  """
  def mark_as_read(notification_id, user_id) do
    now = Elektrine.Time.utc_now()

    notification =
      Repo.get_by(Notification,
        id: notification_id,
        user_id: user_id
      )

    sync_notification_sources_as_read(user_id, [notification])

    from(n in Notification,
      where: n.id == ^notification_id and n.user_id == ^user_id
    )
    |> Repo.update_all(set: [read_at: now, seen_at: now])

    # Invalidate notification cache
    Elektrine.AppCache.invalidate_notification_cache(user_id)

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{user_id}:notifications",
      :notification_updated
    )

    # Broadcast count update
    new_count = get_unread_count(user_id)

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{user_id}:notification_count",
      {:notification_count_updated, new_count}
    )

    :ok
  end

  @doc """
  Marks notifications as read by source.
  Useful for clearing email notifications when the email is read.
  """
  def mark_as_read_by_source(user_id, source_type, source_id) do
    now = Elektrine.Time.utc_now()

    result =
      from(n in Notification,
        where:
          n.user_id == ^user_id and
            n.source_type == ^source_type and
            n.source_id == ^source_id and
            is_nil(n.read_at)
      )
      |> Repo.update_all(set: [read_at: now, seen_at: now])

    # Broadcast count update if any notifications were marked as read
    case result do
      {count, _} when count > 0 ->
        # Invalidate notification cache
        Elektrine.AppCache.invalidate_notification_cache(user_id)

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{user_id}:notifications",
          :notification_updated
        )

        new_count = get_unread_count(user_id)

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{user_id}:notification_count",
          {:notification_count_updated, new_count}
        )

        {:ok, count}

      _ ->
        {:ok, 0}
    end
  end

  @doc """
  Marks notifications as read by multiple source IDs (bulk operation).
  Useful for clearing all message notifications in a conversation.
  """
  def mark_as_read_by_sources(user_id, source_type, source_ids) when is_list(source_ids) do
    now = Elektrine.Time.utc_now()

    result =
      from(n in Notification,
        where:
          n.user_id == ^user_id and
            n.source_type == ^source_type and
            n.source_id in ^source_ids and
            is_nil(n.read_at)
      )
      |> Repo.update_all(set: [read_at: now, seen_at: now])

    # Broadcast count update if any notifications were marked as read
    case result do
      {count, _} when count > 0 ->
        # Invalidate notification cache
        Elektrine.AppCache.invalidate_notification_cache(user_id)

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{user_id}:notifications",
          :notification_updated
        )

        new_count = get_unread_count(user_id)

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{user_id}:notification_count",
          {:notification_count_updated, new_count}
        )

        {:ok, count}

      _ ->
        {:ok, 0}
    end
  end

  @doc """
  Marks all notifications as read for a user.
  """
  def mark_all_as_read(user_id) do
    now = Elektrine.Time.utc_now()

    unread_notifications =
      from(n in Notification,
        where: n.user_id == ^user_id and is_nil(n.read_at)
      )
      |> Repo.all()

    sync_notification_sources_as_read(user_id, unread_notifications)

    from(n in Notification,
      where: n.user_id == ^user_id and is_nil(n.read_at)
    )
    |> Repo.update_all(set: [read_at: now, seen_at: now])

    # Invalidate notification cache
    Elektrine.AppCache.invalidate_notification_cache(user_id)

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{user_id}:notifications",
      :all_notifications_read
    )

    # Broadcast count update (now 0)
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{user_id}:notification_count",
      {:notification_count_updated, 0}
    )

    :ok
  end

  defp sync_notification_sources_as_read(user_id, notifications) do
    notifications =
      notifications
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&is_nil(&1.read_at))

    mark_chat_notification_sources_as_read(user_id, notifications)
    mark_email_notification_sources_as_read(user_id, notifications)

    :ok
  end

  defp mark_chat_notification_sources_as_read(user_id, notifications) do
    notifications
    |> Enum.each(fn
      %Notification{type: type, source_type: "message", source_id: message_id}
      when type in ["new_message", "reply"] and is_integer(message_id) ->
        case Messaging.get_chat_message(message_id) do
          %{conversation_id: conversation_id, sender_id: sender_id, id: id}
          when is_integer(conversation_id) and sender_id != user_id ->
            Messaging.mark_chat_messages_read(conversation_id, user_id, id)

          _ ->
            :ok
        end

      _ ->
        :ok
    end)
  end

  defp mark_email_notification_sources_as_read(user_id, notifications) do
    with true <- email_source_available?(),
         %{id: mailbox_id} <- Elektrine.Email.get_user_mailbox(user_id) do
      Enum.each(notifications, fn
        %Notification{type: "email_received", source_type: "email", source_id: message_id}
        when is_integer(message_id) ->
          case Elektrine.Email.get_message_internal(message_id) do
            %{mailbox_id: ^mailbox_id, read: false} = message ->
              Elektrine.Email.mark_as_read(message)

            _ ->
              :ok
          end

        _ ->
          :ok
      end)
    else
      _ -> :ok
    end
  end

  defp email_source_available? do
    Code.ensure_loaded?(Elektrine.Email) and
      function_exported?(Elektrine.Email, :get_user_mailbox, 1) and
      function_exported?(Elektrine.Email, :get_message_internal, 1) and
      function_exported?(Elektrine.Email, :mark_as_read, 1)
  end

  @doc """
  Marks notifications as seen (but not necessarily read).
  """
  def mark_as_seen(notification_ids, user_id) when is_list(notification_ids) do
    now = Elektrine.Time.utc_now()

    from(n in Notification,
      where: n.id in ^notification_ids and n.user_id == ^user_id and is_nil(n.seen_at)
    )
    |> Repo.update_all(set: [seen_at: now])

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{user_id}:notifications",
      :notifications_seen
    )

    :ok
  end

  @doc """
  Dismisses a notification.
  """
  def dismiss_notification(notification_id, user_id) do
    now = Elektrine.Time.utc_now()

    # Check if this notification was unread before dismissing
    was_unread =
      from(n in Notification,
        where: n.id == ^notification_id and n.user_id == ^user_id and is_nil(n.read_at),
        select: count(n.id)
      )
      |> Repo.one()
      |> Kernel.>(0)

    from(n in Notification,
      where: n.id == ^notification_id and n.user_id == ^user_id
    )
    |> Repo.update_all(set: [dismissed_at: now])

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{user_id}:notifications",
      :notification_dismissed
    )

    # If it was unread, broadcast count update
    if was_unread do
      Elektrine.AppCache.invalidate_notification_cache(user_id)
      new_count = get_unread_count(user_id)

      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "user:#{user_id}:notification_count",
        {:notification_count_updated, new_count}
      )
    end

    :ok
  end

  @doc """
  Dismisses all notifications for a user.
  """
  def dismiss_all_notifications(user_id) do
    now = Elektrine.Time.utc_now()

    from(n in Notification,
      where: n.user_id == ^user_id and is_nil(n.dismissed_at)
    )
    |> Repo.update_all(set: [dismissed_at: now])

    Elektrine.AppCache.invalidate_notification_cache(user_id)

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{user_id}:notifications",
      :all_notifications_dismissed
    )

    # Broadcast count update (now 0)
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{user_id}:notification_count",
      {:notification_count_updated, 0}
    )

    :ok
  end

  defp query_unread_count(user_id) do
    from(n in Notification,
      where: n.user_id == ^user_id and is_nil(n.read_at) and is_nil(n.dismissed_at),
      select: count(n.id)
    )
    |> Repo.one()
  end

  @doc """
  Creates common notification types.
  """
  def notify_new_message(recipient_id, sender, conversation_name, message_preview) do
    # Check if user wants to be notified about direct messages
    user = Elektrine.Accounts.get_user!(recipient_id)

    if notification_preference_enabled?(user, :notify_on_direct_message) do
      create_notification(%{
        type: "new_message",
        title: "New message from @#{sender.handle || sender.username}",
        body: String.slice(message_preview, 0, 100),
        url: Elektrine.Paths.chat_path(conversation_name),
        icon: "hero-chat-bubble-left",
        user_id: recipient_id,
        actor_id: sender.id,
        source_type: "message",
        priority: "normal"
      })
    else
      {:ok, :notification_disabled}
    end
  end

  def notify_mention(mentioned_user_id, actor, source_type, source_id, context) do
    # Check if user wants to be notified about mentions
    user = Elektrine.Accounts.get_user!(mentioned_user_id)

    if notification_preference_enabled?(user, :notify_on_mention) do
      create_notification(%{
        type: "mention",
        title: "@#{actor.handle || actor.username} mentioned you",
        body: context,
        url: build_mention_url(source_type, source_id),
        icon: "hero-at-symbol",
        user_id: mentioned_user_id,
        actor_id: actor.id,
        source_type: source_type,
        source_id: source_id,
        priority: "high"
      })
    else
      {:ok, :notification_disabled}
    end
  end

  def notify_follow(followed_user_id, follower) do
    # Check if user wants to be notified about new followers
    user = Elektrine.Accounts.get_user!(followed_user_id)

    if notification_preference_enabled?(user, :notify_on_new_follower) do
      create_notification(%{
        type: "follow",
        title: "@#{follower.handle || follower.username} started following you",
        body: nil,
        url: "/#{follower.handle || follower.username}",
        icon: "hero-user-plus",
        user_id: followed_user_id,
        actor_id: follower.id,
        source_type: "user",
        source_id: follower.id,
        priority: "normal"
      })
    else
      {:ok, :notification_disabled}
    end
  end

  def notify_like(content_owner_id, liker, source_type, source_id) do
    create_notification(%{
      type: "like",
      title: "@#{liker.handle || liker.username} liked your #{source_type}",
      body: nil,
      url: build_content_url(source_type, source_id),
      icon: "hero-heart",
      user_id: content_owner_id,
      actor_id: liker.id,
      source_type: source_type,
      source_id: source_id,
      priority: "low"
    })
  end

  def notify_reaction(content_owner_id, reactor, emoji, source_type, source_id) do
    # Don't notify if reacting to own content
    if content_owner_id == reactor.id do
      {:ok, :self_reaction}
    else
      create_notification(%{
        type: "reaction",
        title: "@#{reactor.handle || reactor.username} reacted #{emoji} to your #{source_type}",
        body: nil,
        url: build_content_url(source_type, source_id),
        icon: "hero-face-smile",
        user_id: content_owner_id,
        actor_id: reactor.id,
        source_type: source_type,
        source_id: source_id,
        priority: "low"
      })
    end
  end

  def notify_reply(original_poster_id, replier, source_type, source_id, reply_preview) do
    create_notification(%{
      type: "reply",
      title: "@#{replier.handle || replier.username} replied to your #{source_type}",
      body: String.slice(reply_preview, 0, 100),
      url: build_content_url(source_type, source_id),
      icon: "hero-chat-bubble-left",
      user_id: original_poster_id,
      actor_id: replier.id,
      source_type: source_type,
      source_id: source_id,
      priority: "normal"
    })
  end

  defp build_mention_url("message", message_id),
    do: Elektrine.Paths.chat_root_message_path(message_id)

  defp build_mention_url("post", post_id), do: Elektrine.Paths.post_path(post_id)

  defp build_mention_url("discussion", discussion_id),
    do: Elektrine.Paths.post_path(discussion_id)

  defp build_mention_url(_, _), do: "/"

  defp build_content_url("post", post_id), do: Elektrine.Paths.post_path(post_id)

  defp build_content_url("discussion", discussion_id),
    do: Elektrine.Paths.post_path(discussion_id)

  defp build_content_url(_, _), do: "/"

  defp resolve_legacy_message_notification_urls(notifications) when is_list(notifications) do
    source_ids =
      notifications
      |> Enum.filter(&legacy_message_notification_url?/1)
      |> Enum.map(& &1.source_id)
      |> Enum.uniq()

    if source_ids == [] do
      notifications
    else
      {messages_by_id, parents_by_id} = load_messages_with_parents(source_ids)

      Enum.map(notifications, fn notification ->
        if legacy_message_notification_url?(notification) do
          case Map.get(messages_by_id, notification.source_id) do
            %Message{} = message ->
              resolved_url =
                build_message_notification_url(
                  message,
                  Map.get(parents_by_id, message.reply_to_id),
                  notification.type
                )

              if is_binary(resolved_url) and resolved_url != "" do
                %{notification | url: resolved_url}
              else
                notification
              end

            nil ->
              notification
          end
        else
          notification
        end
      end)
    end
  end

  defp legacy_message_notification_url?(%Notification{
         source_type: "message",
         source_id: source_id,
         url: url
       })
       when is_integer(source_id) do
    is_nil(url) or url == "" or
      String.starts_with?(url, ["/timeline/post/", "/remote/post/", "/post/", "#message-"])
  end

  defp legacy_message_notification_url?(_), do: false

  defp load_messages_with_parents(message_ids) when is_list(message_ids) do
    messages =
      from(m in Message, where: m.id in ^message_ids, preload: [:conversation])
      |> Repo.all()

    parent_ids =
      messages
      |> Enum.map(& &1.reply_to_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    parents =
      if parent_ids == [] do
        []
      else
        from(m in Message, where: m.id in ^parent_ids, preload: [:conversation])
        |> Repo.all()
      end

    {Map.new(messages, &{&1.id, &1}), Map.new(parents, &{&1.id, &1})}
  end

  defp build_message_notification_url(
         %Message{federated: true} = message,
         %Message{} = parent,
         notification_type
       )
       when notification_type in ["reply", "mention", "comment", "discussion_reply"] do
    Elektrine.Paths.remote_post_path(parent.id) <> threaded_message_anchor(parent, message)
  end

  defp build_message_notification_url(
         %Message{} = message,
         %Message{} = parent,
         notification_type
       )
       when notification_type in ["reply", "mention", "comment", "discussion_reply"] do
    build_message_path(parent) <> threaded_message_anchor(parent, message)
  end

  defp build_message_notification_url(%Message{} = message, _parent, _notification_type) do
    build_message_path(message)
  end

  defp build_message_path(%Message{
         id: id,
         conversation: %{type: type} = conversation
       })
       when type in ["dm", "group", "channel"] do
    conversation_ref = conversation.hash || conversation.id
    Elektrine.Paths.chat_message_path(conversation_ref, id)
  end

  defp build_message_path(%Message{
         id: id,
         conversation: %{type: "community", name: name}
       })
       when is_binary(name) and name != "" do
    Elektrine.Paths.discussion_post_path(name, id)
  end

  defp build_message_path(%Message{federated: true, id: id}),
    do: Elektrine.Paths.remote_post_path(id)

  defp build_message_path(%Message{} = message), do: Elektrine.Paths.post_path(message)

  defp threaded_message_anchor(%Message{conversation: %{type: "community"}}, %Message{id: id}),
    do: Elektrine.Paths.post_anchor(id)

  defp threaded_message_anchor(_parent, %Message{id: id}),
    do: Elektrine.Paths.post_anchor(id)

  defp notification_preference_enabled?(subject, field) when is_atom(field) do
    Map.get(subject, field) != false
  end

  defp maybe_emit_developer_webhook(%Notification{} = notif, unread_count) do
    case notification_webhook_event(notif.type) do
      nil ->
        :ok

      event ->
        payload = %{
          notification_id: notif.id,
          type: notif.type,
          title: notif.title,
          body: notif.body,
          url: notif.url,
          source_type: notif.source_type,
          source_id: notif.source_id,
          actor_id: notif.actor_id,
          unread_count: unread_count,
          inserted_at: notif.inserted_at
        }

        _ = Elektrine.Developer.deliver_event(notif.user_id, event, payload)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp notification_webhook_event("email_received"), do: "email.received"
  defp notification_webhook_event("new_message"), do: "message.received"
  defp notification_webhook_event("reply"), do: "message.received"
  defp notification_webhook_event("like"), do: "post.liked"
  defp notification_webhook_event("follow"), do: "follow.new"
  defp notification_webhook_event(_), do: nil
end
