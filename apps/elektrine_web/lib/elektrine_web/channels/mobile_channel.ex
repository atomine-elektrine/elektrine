defmodule ElektrineWeb.MobileChannel do
  @moduledoc """
  Unified Phoenix Channel for mobile app real-time updates.
  Provides live updates for emails, notifications, chat, social features, and other events.
  """
  use ElektrineWeb, :channel
  require Logger

  alias Elektrine.{Accounts, Email, Notifications, Profiles, Social, VPN}
  alias Elektrine.Messaging, as: Messaging
  alias Elektrine.PubSubTopics

  @impl true
  def join("mobile:user", _params, socket) do
    user_id = socket.assigns.user_id

    # Subscribe to user-specific topics
    PubSubTopics.subscribe("user:#{user_id}")
    PubSubTopics.subscribe(PubSubTopics.user_notifications(user_id))
    PubSubTopics.subscribe("user:#{user_id}:notification_count")
    PubSubTopics.subscribe(PubSubTopics.user_vpn(user_id))

    # Subscribe to mailbox updates if user has a mailbox
    if mailbox = Email.get_user_mailbox(user_id) do
      PubSubTopics.subscribe("mailbox:#{mailbox.id}")
    end

    # Subscribe to all user's conversations for chat updates
    conversations = Messaging.list_conversations(user_id)

    for conv <- conversations do
      PubSubTopics.subscribe(PubSubTopics.conversation(conv.id))
    end

    # Subscribe to social topics
    PubSubTopics.subscribe("social:user:#{user_id}")
    PubSubTopics.subscribe("social:followers:#{user_id}")
    PubSubTopics.subscribe("social:notifications:#{user_id}")

    # Track presence for online detection
    {:ok, _} =
      ElektrineWeb.Presence.track(self(), "mobile:users", to_string(user_id), %{
        user_id: user_id,
        online_at: System.system_time(:second),
        platform: "mobile"
      })

    send(self(), :after_join)
    {:ok, assign(socket, :joined_conversations, MapSet.new(Enum.map(conversations, & &1.id)))}
  end

  def join("mobile:" <> _other, _params, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id

    # Push initial state
    mailbox = Email.get_user_mailbox(user_id)

    if mailbox do
      # Push unread counts
      counts = Email.Messages.get_all_unread_counts(mailbox.id)
      push(socket, "email:counts", %{counts: counts})
    end

    # Push notification count
    notification_count = Notifications.get_unread_count(user_id)
    push(socket, "notification:count", %{count: notification_count})

    # Push social counts
    push(socket, "social:counts", %{
      follower_count: Profiles.get_follower_count(user_id),
      following_count: Profiles.get_following_count(user_id)
    })

    push(socket, "vpn:counts", %{config_count: user_id |> VPN.list_user_configs() |> length()})

    push(socket, "event:stream_ready", %{
      sources: ["email", "notification", "chat", "social", "vpn"],
      connected_at: DateTime.utc_now()
    })

    {:noreply, socket}
  end

  # Handle new email received
  @impl true
  def handle_info({:new_email, message}, socket) do
    socket =
      socket
      |> push("email:new", %{
        id: message.id,
        from: message.from,
        subject: message.subject,
        preview: truncate_preview(message.text_body),
        category: message.category,
        has_attachments: message.has_attachments,
        inserted_at: message.inserted_at
      })
      |> push_universal_event("email", "new", %{
        title: email_title(message),
        body: truncate_preview(message.subject),
        url: "/email/view/#{message.hash || message.id}",
        category: message.category,
        message_id: message.id
      })

    # Also update counts
    user_id = socket.assigns.user_id

    if mailbox = Email.get_user_mailbox(user_id) do
      counts = Email.Messages.get_all_unread_counts(mailbox.id)
      push(socket, "email:counts", %{counts: counts})
    end

    {:noreply, socket}
  end

  # Handle email status updates
  @impl true
  def handle_info({:email_updated, message}, socket) do
    socket =
      socket
      |> push("email:updated", %{
        id: message.id,
        read: message.read,
        archived: message.archived,
        spam: message.spam,
        deleted: message.deleted,
        category: message.category
      })
      |> push_universal_event("email", "updated", %{
        title: "Email updated",
        body: "Message ##{message.id} status changed",
        url: "/email/view/#{message.hash || message.id}",
        message_id: message.id,
        read: message.read,
        archived: message.archived,
        deleted: message.deleted
      })

    {:noreply, socket}
  end

  # Handle new notification
  @impl true
  def handle_info({:new_notification, notification}, socket) do
    formatted = format_notification(notification)

    socket =
      socket
      |> push("notification:new", formatted)
      |> push_universal_event("notification", "new", %{
        title: formatted.title,
        body: formatted.body,
        url: formatted.url,
        notification_id: formatted.id,
        type: formatted.type
      })

    {:noreply, socket}
  end

  # Handle notification count updates
  @impl true
  def handle_info({:notification_count_updated, count}, socket) do
    socket =
      socket
      |> push("notification:count", %{count: count})
      |> push_universal_event("notification", "count_updated", %{
        title: "Notification count updated",
        body: "#{count} unread notification(s)",
        url: "/notifications",
        count: count
      })

    {:noreply, socket}
  end

  # Handle all notifications read
  @impl true
  def handle_info(:all_notifications_read, socket) do
    socket =
      socket
      |> push("notification:count", %{count: 0})
      |> push_universal_event("notification", "all_read", %{
        title: "Notifications cleared",
        body: "All notifications marked as read",
        url: "/notifications",
        count: 0
      })

    {:noreply, socket}
  end

  # Chat message events
  @impl true
  def handle_info({:new_chat_message, message}, socket) do
    formatted = format_chat_message(message)

    socket =
      socket
      |> push("chat:new_message", formatted)
      |> push_universal_event("chat", "message_created", %{
        title: "New chat message",
        body: truncate_preview(formatted.content),
        url: "/chat/#{formatted.conversation_id}",
        conversation_id: formatted.conversation_id,
        message_id: formatted.id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_message_updated, message}, socket) do
    formatted = format_chat_message(message)

    socket =
      socket
      |> push("chat:message_updated", formatted)
      |> push_universal_event("chat", "message_updated", %{
        title: "Chat message updated",
        body: truncate_preview(formatted.content),
        url: "/chat/#{formatted.conversation_id}",
        conversation_id: formatted.conversation_id,
        message_id: formatted.id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_message_deleted, message_id}, socket) do
    socket =
      socket
      |> push("chat:message_deleted", %{message_id: message_id})
      |> push_universal_event("chat", "message_deleted", %{
        title: "Chat message deleted",
        body: "Message ##{message_id} was removed",
        url: "/chat",
        message_id: message_id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_reaction_added, message_id, reaction}, socket) do
    push(socket, "chat:reaction_added", %{
      message_id: message_id,
      reaction: %{
        id: reaction.id,
        emoji: reaction.emoji,
        user_id: reaction.user_id
      }
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_reaction_removed, message_id, user_id, emoji}, socket) do
    push(socket, "chat:reaction_removed", %{
      message_id: message_id,
      user_id: user_id,
      emoji: emoji
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:user_typing, conversation_id, user_id, username}, socket) do
    push(socket, "chat:user_typing", %{
      conversation_id: conversation_id,
      user_id: user_id,
      username: username
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:user_stopped_typing, conversation_id, user_id}, socket) do
    push(socket, "chat:user_stopped_typing", %{
      conversation_id: conversation_id,
      user_id: user_id
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:read_receipt, conversation_id, user_id, message_id}, socket) do
    push(socket, "chat:read_receipt", %{
      conversation_id: conversation_id,
      user_id: user_id,
      message_id: message_id
    })

    {:noreply, socket}
  end

  # === Social Events ===

  # Handle new post from followed user
  @impl true
  def handle_info({:new_post, post}, socket) do
    formatted = format_post(post)

    socket =
      socket
      |> push("post:new", formatted)
      |> push_universal_event("social", "post_created", %{
        title: "New post",
        body: truncate_preview(formatted.content),
        url: "/timeline/post/#{formatted.id}",
        post_id: formatted.id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:post_updated, post}, socket) do
    formatted = format_post(post)

    socket =
      socket
      |> push("post:updated", formatted)
      |> push_universal_event("social", "post_updated", %{
        title: "Post updated",
        body: truncate_preview(formatted.content),
        url: "/timeline/post/#{formatted.id}",
        post_id: formatted.id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:post_deleted, post_id}, socket) do
    socket =
      socket
      |> push("post:deleted", %{id: post_id})
      |> push_universal_event("social", "post_deleted", %{
        title: "Post deleted",
        body: "Post ##{post_id} was removed",
        url: "/timeline",
        post_id: post_id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:post_liked, %{post_id: post_id, user_id: liker_id, like_count: count}},
        socket
      ) do
    socket =
      socket
      |> push("post:liked", %{post_id: post_id, liker_id: liker_id, like_count: count})
      |> push_universal_event("social", "post_liked", %{
        title: "Post liked",
        body: "Post ##{post_id} now has #{count} like(s)",
        url: "/timeline/post/#{post_id}",
        post_id: post_id,
        like_count: count
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:post_unliked, %{post_id: post_id, like_count: count}}, socket) do
    socket =
      socket
      |> push("post:unliked", %{post_id: post_id, like_count: count})
      |> push_universal_event("social", "post_unliked", %{
        title: "Post unliked",
        body: "Post ##{post_id} now has #{count} like(s)",
        url: "/timeline/post/#{post_id}",
        post_id: post_id,
        like_count: count
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_comment, comment}, socket) do
    formatted = format_comment(comment)

    socket =
      socket
      |> push("comment:new", formatted)
      |> push_universal_event("social", "comment_created", %{
        title: "New comment",
        body: truncate_preview(formatted.content),
        url: "/timeline/post/#{formatted.post_id}",
        comment_id: formatted.id,
        post_id: formatted.post_id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:comment_deleted, comment_id}, socket) do
    socket =
      socket
      |> push("comment:deleted", %{id: comment_id})
      |> push_universal_event("social", "comment_deleted", %{
        title: "Comment deleted",
        body: "Comment ##{comment_id} was removed",
        url: "/timeline",
        comment_id: comment_id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:post_reposted, %{post_id: post_id, user_id: reposter_id, repost_count: count}},
        socket
      ) do
    socket =
      socket
      |> push("post:reposted", %{
        post_id: post_id,
        reposter_id: reposter_id,
        repost_count: count
      })
      |> push_universal_event("social", "post_reposted", %{
        title: "Post reposted",
        body: "Post ##{post_id} now has #{count} repost(s)",
        url: "/timeline/post/#{post_id}",
        post_id: post_id,
        repost_count: count
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_follower, follower}, socket) do
    user_id = socket.assigns.user_id

    socket =
      socket
      |> push("follower:new", %{
        id: follower.id,
        username: follower.username,
        display_name: follower.display_name,
        avatar: follower.avatar_url
      })
      |> push("social:counts", %{
        follower_count: Profiles.get_follower_count(user_id),
        following_count: Profiles.get_following_count(user_id)
      })
      |> push_universal_event("social", "follower_added", %{
        title: "New follower",
        body: "@#{follower.username} started following you",
        url: "/#{follower.handle || follower.username}",
        follower_id: follower.id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:unfollowed, follower_id}, socket) do
    user_id = socket.assigns.user_id

    socket =
      socket
      |> push("follower:removed", %{id: follower_id})
      |> push("social:counts", %{
        follower_count: Profiles.get_follower_count(user_id),
        following_count: Profiles.get_following_count(user_id)
      })
      |> push_universal_event("social", "follower_removed", %{
        title: "Follower removed",
        body: "Follower ##{follower_id} is no longer following",
        url: "/friends",
        follower_id: follower_id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:friend_request, request}, socket) do
    socket =
      socket
      |> push("friend_request:new", %{
        id: request.id,
        user_id: request.requester_id,
        username: request.requester.username,
        display_name: request.requester.display_name,
        avatar: request.requester.avatar_url,
        created_at: request.inserted_at
      })
      |> push_universal_event("social", "friend_request_received", %{
        title: "Friend request",
        body: "@#{request.requester.username} sent you a request",
        url: "/friends?tab=requests",
        request_id: request.id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:friend_request_accepted, request}, socket) do
    socket =
      socket
      |> push("friend_request:accepted", %{id: request.id, user_id: request.recipient_id})
      |> push_universal_event("social", "friend_request_accepted", %{
        title: "Friend request accepted",
        body: "You are now connected",
        url: "/friends",
        request_id: request.id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:social_notification, notification}, socket) do
    formatted = format_notification(notification)

    socket =
      socket
      |> push("notification:new", formatted)
      |> push_universal_event("social", "notification", %{
        title: formatted.title,
        body: formatted.body,
        url: formatted.url,
        notification_id: formatted.id,
        type: formatted.type
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:vpn_config_created, config}, socket) do
    formatted = format_vpn_config(config)
    count = socket.assigns.user_id |> VPN.list_user_configs() |> length()

    socket =
      socket
      |> push("vpn:config_created", formatted)
      |> push("vpn:counts", %{config_count: count})
      |> push_universal_event("vpn", "config_created", %{
        title: "VPN profile created",
        body: "#{formatted.server_name} - #{formatted.allocated_ip}",
        url: "/vpn",
        config_id: formatted.id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:vpn_config_updated, config}, socket) do
    formatted = format_vpn_config(config)
    count = socket.assigns.user_id |> VPN.list_user_configs() |> length()

    socket =
      socket
      |> push("vpn:config_updated", formatted)
      |> push("vpn:counts", %{config_count: count})
      |> push_universal_event("vpn", "config_updated", %{
        title: "VPN profile updated",
        body: "#{formatted.server_name} - status #{formatted.status}",
        url: "/vpn",
        config_id: formatted.id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:vpn_config_deleted, config_id}, socket) do
    count = socket.assigns.user_id |> VPN.list_user_configs() |> length()

    socket =
      socket
      |> push("vpn:config_deleted", %{id: config_id})
      |> push("vpn:counts", %{config_count: count})
      |> push_universal_event("vpn", "config_deleted", %{
        title: "VPN profile removed",
        body: "VPN config ##{config_id} was removed",
        url: "/vpn",
        config_id: config_id
      })

    {:noreply, socket}
  end

  # Ignore other PubSub messages
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Client-initiated events

  @impl true
  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{ts: System.system_time(:second)}}, socket}
  end

  @impl true
  def handle_in("mark_email_read", %{"id" => id}, socket) do
    user_id = socket.assigns.user_id

    case Email.get_user_message(id, user_id) do
      {:ok, message} ->
        Email.mark_as_read(message)
        {:reply, :ok, socket}

      _ ->
        {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  @impl true
  def handle_in("mark_notification_read", %{"id" => id}, socket) do
    user_id = socket.assigns.user_id

    case Notifications.mark_as_read(id, user_id) do
      :ok -> {:reply, :ok, socket}
      _ -> {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  @impl true
  def handle_in("get_counts", _payload, socket) do
    user_id = socket.assigns.user_id
    mailbox = Email.get_user_mailbox(user_id)

    counts =
      if mailbox do
        Email.Messages.get_all_unread_counts(mailbox.id)
      else
        %{}
      end

    notification_count = Notifications.get_unread_count(user_id)

    {:reply, {:ok, %{email_counts: counts, notification_count: notification_count}}, socket}
  end

  # Chat events

  @impl true
  def handle_in("chat:join_conversation", %{"conversation_id" => conv_id}, socket) do
    user_id = socket.assigns.user_id

    # Verify membership
    case Messaging.get_conversation_member(conv_id, user_id) do
      nil ->
        {:reply, {:error, %{reason: "not_member"}}, socket}

      _member ->
        # Subscribe if not already
        joined = socket.assigns[:joined_conversations] || MapSet.new()

        unless MapSet.member?(joined, conv_id) do
          PubSubTopics.subscribe(PubSubTopics.conversation(conv_id))
        end

        {:reply, :ok, assign(socket, :joined_conversations, MapSet.put(joined, conv_id))}
    end
  end

  @impl true
  def handle_in("chat:typing", %{"conversation_id" => conv_id}, socket) do
    user_id = socket.assigns.user_id
    user = Accounts.get_user!(user_id)

    # Broadcast to conversation
    topic = PubSubTopics.conversation(conv_id)

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      topic,
      {:user_typing, conv_id, user_id, user.username}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_in("chat:stop_typing", %{"conversation_id" => conv_id}, socket) do
    user_id = socket.assigns.user_id

    topic = PubSubTopics.conversation(conv_id)
    Phoenix.PubSub.broadcast(Elektrine.PubSub, topic, {:user_stopped_typing, conv_id, user_id})

    {:noreply, socket}
  end

  @impl true
  def handle_in(
        "chat:read_message",
        %{"conversation_id" => conv_id, "message_id" => msg_id},
        socket
      ) do
    user_id = socket.assigns.user_id

    # Mark as read
    Messaging.mark_chat_messages_read(conv_id, user_id, msg_id)

    # Broadcast read receipt
    topic = PubSubTopics.conversation(conv_id)
    Phoenix.PubSub.broadcast(Elektrine.PubSub, topic, {:read_receipt, conv_id, user_id, msg_id})

    {:noreply, socket}
  end

  @impl true
  def handle_in("chat:get_unread_counts", _payload, socket) do
    user_id = socket.assigns.user_id
    counts = Messaging.get_all_chat_unread_counts(user_id)
    {:reply, {:ok, %{counts: counts}}, socket}
  end

  # === Social Client Events ===

  @impl true
  def handle_in("like_post", %{"post_id" => post_id}, socket) do
    user_id = socket.assigns.user_id

    case Social.like_post(user_id, post_id) do
      {:ok, _} -> {:reply, {:ok, %{message: "Post liked"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("unlike_post", %{"post_id" => post_id}, socket) do
    user_id = socket.assigns.user_id

    case Social.unlike_post(user_id, post_id) do
      {:ok, _} -> {:reply, {:ok, %{message: "Post unliked"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("repost", %{"post_id" => post_id}, socket) do
    user_id = socket.assigns.user_id

    case Social.boost_post(user_id, post_id) do
      {:ok, boost} -> {:reply, {:ok, %{post: format_post(boost)}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("unrepost", %{"post_id" => post_id}, socket) do
    user_id = socket.assigns.user_id

    case Social.unboost_post(user_id, post_id) do
      {:ok, _} -> {:reply, {:ok, %{message: "Repost removed"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("follow", %{"user_id" => target_id}, socket) do
    user_id = socket.assigns.user_id

    case Profiles.follow_user(user_id, target_id) do
      {:ok, _} -> {:reply, {:ok, %{message: "Following user"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("unfollow", %{"user_id" => target_id}, socket) do
    user_id = socket.assigns.user_id

    case Profiles.unfollow_user(user_id, target_id) do
      {:ok, _} -> {:reply, {:ok, %{message: "Unfollowed user"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("mark_all_notifications_read", _payload, socket) do
    user_id = socket.assigns.user_id
    Notifications.mark_all_as_read(user_id)
    push(socket, "notification:count", %{count: 0})
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("get_social_counts", _payload, socket) do
    user_id = socket.assigns.user_id

    {:reply,
     {:ok,
      %{
        follower_count: Profiles.get_follower_count(user_id),
        following_count: Profiles.get_following_count(user_id),
        notification_count: Notifications.get_unread_count(user_id)
      }}, socket}
  end

  # Private helpers

  defp truncate_preview(nil), do: ""

  defp truncate_preview(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.slice(0, 100)
  end

  defp push_universal_event(socket, source, event, attrs) when is_map(attrs) do
    payload =
      attrs
      |> Map.put_new(:id, event_id())
      |> Map.put_new(:source, source)
      |> Map.put_new(:event, event)
      |> Map.put_new(:inserted_at, DateTime.utc_now())

    push(socket, "event:new", payload)
  end

  defp push_universal_event(socket, source, event, _attrs) do
    push_universal_event(socket, source, event, %{})
  end

  defp email_title(message) do
    from = message.from |> to_string() |> String.trim()

    if from == "" do
      "New email"
    else
      "New email from #{from}"
    end
  end

  defp event_id do
    "evt_" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp format_vpn_config(config) do
    %{
      id: config.id,
      server_name: vpn_server_name(config),
      allocated_ip: config.allocated_ip,
      status: config.status,
      inserted_at: config.inserted_at,
      updated_at: config.updated_at
    }
  end

  defp vpn_server_name(%{vpn_server: %{name: name}}) when is_binary(name) and name != "", do: name
  defp vpn_server_name(_), do: "VPN"

  defp format_notification(notification) do
    %{
      id: notification.id,
      type: notification.type,
      title: notification.title,
      body: notification.body,
      url: notification.url,
      icon: notification.icon,
      read: notification.read,
      inserted_at: notification.inserted_at
    }
  end

  defp format_chat_message(message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      sender: format_user(message.sender),
      content: message.content,
      message_type: message.message_type,
      media_urls: message.media_urls || [],
      media_metadata: message.media_metadata || %{},
      reply_to_id: message.reply_to_id,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      inserted_at: message.inserted_at
    }
  end

  defp format_user(nil), do: nil
  defp format_user(%Ecto.Association.NotLoaded{}), do: nil

  defp format_user(user) do
    %{
      id: user.id,
      username: user.username,
      avatar: user.avatar
    }
  end

  defp format_post(post) do
    %{
      id: post.id,
      content: post.content,
      media_urls: post.media_urls || [],
      author_id: post.sender_id,
      community_id: post.conversation_id,
      visibility: post.visibility || "public",
      like_count: post.like_count || 0,
      comment_count: post.reply_count || 0,
      repost_count: post.share_count || 0,
      created_at: post.inserted_at,
      author: format_author(post.sender)
    }
  end

  defp format_author(nil), do: nil
  defp format_author(%Ecto.Association.NotLoaded{}), do: nil

  defp format_author(user) do
    %{
      id: user.id,
      username: user.username,
      display_name: user.display_name,
      avatar: user.avatar_url,
      verified: user.verified || false
    }
  end

  defp format_comment(comment) do
    %{
      id: comment.id,
      content: comment.content,
      author_id: comment.sender_id,
      post_id: comment.reply_to_id,
      parent_id: comment.parent_id,
      like_count: comment.like_count || 0,
      reply_count: comment.reply_count || 0,
      created_at: comment.inserted_at,
      author: format_author(comment.sender)
    }
  end
end
