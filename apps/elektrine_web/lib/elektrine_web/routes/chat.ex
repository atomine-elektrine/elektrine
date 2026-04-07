defmodule ElektrineWeb.Routes.Chat do
  @moduledoc false

  defmacro private_attachment_routes do
    quote do
      get("/private-attachments/:token", PrivateAttachmentController, :show)
    end
  end

  defmacro messaging_federation_routes do
    quote do
      post("/events", MessagingFederationController, :event)
      post("/events/batch", MessagingFederationController, :event_batch)
      post("/ephemeral", MessagingFederationController, :ephemeral)
      post("/sync", MessagingFederationController, :sync)
      get("/streams/events", MessagingFederationController, :stream_events)
      get("/servers/:server_id/snapshot", MessagingFederationController, :snapshot)
    end
  end

  defmacro messaging_federation_session_routes do
    quote do
      get("/session", MessagingFederationController, :session_websocket)
    end
  end

  defmacro public_directory_routes do
    quote do
      get("/servers/public", MessagingFederationController, :public_servers)
    end
  end

  defmacro public_schema_routes do
    quote do
      get("/profiles", MessagingFederationController, :profiles)
      get("/:version/schemas/:name", MessagingFederationController, :schema)
    end
  end

  defmacro well_known_routes do
    quote do
      get("/_arblarg", MessagingFederationController, :well_known)
      get("/_arblarg/:version", MessagingFederationController, :well_known_versioned)
    end
  end

  defmacro admin_routes do
    quote do
      scope "/", alias: false do
        get("/arblarg/messages", ElektrineChatWeb.Admin.ChatMessagesController, :index)
        get("/arblarg/messages/:id/view", ElektrineChatWeb.Admin.ChatMessagesController, :view)
        get("/arblarg/messages/:id/raw", ElektrineChatWeb.Admin.ChatMessagesController, :view_raw)
      end
    end
  end

  defmacro authenticated_api_routes do
    quote do
      get("/servers", ElektrineChatWeb.API.ServerController, :index)
      post("/servers", ElektrineChatWeb.API.ServerController, :create)
      get("/servers/:id", ElektrineChatWeb.API.ServerController, :show)
      post("/servers/:server_id/join", ElektrineChatWeb.API.ServerController, :join)
      post("/servers/:server_id/channels", ElektrineChatWeb.API.ServerController, :create_channel)

      get("/conversations", ElektrineChatWeb.API.ConversationController, :index)
      post("/conversations", ElektrineChatWeb.API.ConversationController, :create)
      get("/conversations/:id", ElektrineChatWeb.API.ConversationController, :show)
      put("/conversations/:id", ElektrineChatWeb.API.ConversationController, :update)
      delete("/conversations/:id", ElektrineChatWeb.API.ConversationController, :delete)

      post(
        "/conversations/:conversation_id/join",
        ElektrineChatWeb.API.ConversationController,
        :join
      )

      post(
        "/conversations/:conversation_id/leave",
        ElektrineChatWeb.API.ConversationController,
        :leave
      )

      post(
        "/conversations/:conversation_id/read",
        ElektrineChatWeb.API.ConversationController,
        :mark_read
      )

      get(
        "/conversations/:conversation_id/members",
        ElektrineChatWeb.API.ConversationController,
        :members
      )

      post(
        "/conversations/:conversation_id/members",
        ElektrineChatWeb.API.ConversationController,
        :add_member
      )

      get(
        "/conversations/:conversation_id/remote-join-requests",
        ElektrineChatWeb.API.ConversationController,
        :pending_remote_join_requests
      )

      post(
        "/conversations/:conversation_id/remote-join-requests/approve",
        ElektrineChatWeb.API.ConversationController,
        :approve_remote_join_request
      )

      post(
        "/conversations/:conversation_id/remote-join-requests/decline",
        ElektrineChatWeb.API.ConversationController,
        :decline_remote_join_request
      )

      delete(
        "/conversations/:conversation_id/members/:user_id",
        ElektrineChatWeb.API.ConversationController,
        :remove_member
      )

      get(
        "/conversations/:conversation_id/messages",
        ElektrineChatWeb.API.MessageController,
        :index
      )

      post(
        "/conversations/:conversation_id/messages",
        ElektrineChatWeb.API.MessageController,
        :create
      )

      put("/messages/:id", ElektrineChatWeb.API.MessageController, :update)
      delete("/messages/:id", ElektrineChatWeb.API.MessageController, :delete)

      post(
        "/conversations/:conversation_id/upload",
        ElektrineChatWeb.API.ConversationController,
        :upload_media
      )

      post(
        "/messages/:message_id/reactions",
        ElektrineChatWeb.API.MessageController,
        :add_reaction
      )

      delete(
        "/messages/:message_id/reactions/:emoji",
        ElektrineChatWeb.API.MessageController,
        :remove_reaction
      )
    end
  end

  defmacro ext_api_read_routes do
    quote do
      get("/conversations", ElektrineChatWeb.API.ExtChatController, :index)
      get("/conversations/:id", ElektrineChatWeb.API.ExtChatController, :show)
      get("/conversations/:id/messages", ElektrineChatWeb.API.ExtChatController, :messages)
    end
  end

  defmacro ext_api_write_routes do
    quote do
      post("/conversations/:id/messages", ElektrineChatWeb.API.ExtChatController, :create)
    end
  end

  defmacro main_live_routes do
    quote do
      scope "/", alias: false do
        live("/chat", ElektrineChatWeb.ChatLive.Index, :index)
        live("/chat/:conversation_id", ElektrineChatWeb.ChatLive.Index, :conversation)
        live("/chat/join/:conversation_id", ElektrineChatWeb.ChatLive.Index, :join)
      end
    end
  end

  def path_prefixes do
    [
      "/chat",
      "/friends",
      "/_arblarg",
      "/api/private-attachments",
      "/api/servers",
      "/api/conversations",
      "/api/messages",
      "/api/ext/v1/chat",
      "/pripyat/arblarg/messages"
    ]
  end

  def view_modules do
    [ElektrineChatWeb.ChatLive.Index, ElektrineWeb.FriendsLive]
  end
end
