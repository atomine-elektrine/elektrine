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
        get("/arblarg/messages", ArblargWeb.Admin.ChatMessagesController, :index)
        get("/arblarg/messages/:id/view", ArblargWeb.Admin.ChatMessagesController, :view)
        get("/arblarg/messages/:id/raw", ArblargWeb.Admin.ChatMessagesController, :view_raw)
      end
    end
  end

  defmacro authenticated_api_routes do
    quote do
      get("/servers", ArblargWeb.API.ServerController, :index)
      post("/servers", ArblargWeb.API.ServerController, :create)
      get("/servers/:id", ArblargWeb.API.ServerController, :show)
      post("/servers/:server_id/join", ArblargWeb.API.ServerController, :join)
      post("/servers/:server_id/channels", ArblargWeb.API.ServerController, :create_channel)

      get("/conversations", ArblargWeb.API.ConversationController, :index)
      post("/conversations", ArblargWeb.API.ConversationController, :create)
      get("/conversations/:id", ArblargWeb.API.ConversationController, :show)
      put("/conversations/:id", ArblargWeb.API.ConversationController, :update)
      delete("/conversations/:id", ArblargWeb.API.ConversationController, :delete)

      post(
        "/conversations/:conversation_id/join",
        ArblargWeb.API.ConversationController,
        :join
      )

      post(
        "/conversations/:conversation_id/leave",
        ArblargWeb.API.ConversationController,
        :leave
      )

      post(
        "/conversations/:conversation_id/read",
        ArblargWeb.API.ConversationController,
        :mark_read
      )

      get(
        "/conversations/:conversation_id/members",
        ArblargWeb.API.ConversationController,
        :members
      )

      post(
        "/conversations/:conversation_id/members",
        ArblargWeb.API.ConversationController,
        :add_member
      )

      get(
        "/conversations/:conversation_id/remote-join-requests",
        ArblargWeb.API.ConversationController,
        :pending_remote_join_requests
      )

      post(
        "/conversations/:conversation_id/remote-join-requests/approve",
        ArblargWeb.API.ConversationController,
        :approve_remote_join_request
      )

      post(
        "/conversations/:conversation_id/remote-join-requests/decline",
        ArblargWeb.API.ConversationController,
        :decline_remote_join_request
      )

      delete(
        "/conversations/:conversation_id/members/:user_id",
        ArblargWeb.API.ConversationController,
        :remove_member
      )

      get(
        "/conversations/:conversation_id/messages",
        ArblargWeb.API.MessageController,
        :index
      )

      post(
        "/conversations/:conversation_id/messages",
        ArblargWeb.API.MessageController,
        :create
      )

      put("/messages/:id", ArblargWeb.API.MessageController, :update)
      delete("/messages/:id", ArblargWeb.API.MessageController, :delete)

      post(
        "/conversations/:conversation_id/upload",
        ArblargWeb.API.ConversationController,
        :upload_media
      )

      post(
        "/messages/:message_id/reactions",
        ArblargWeb.API.MessageController,
        :add_reaction
      )

      delete(
        "/messages/:message_id/reactions/:emoji",
        ArblargWeb.API.MessageController,
        :remove_reaction
      )
    end
  end

  defmacro ext_api_read_routes do
    quote do
      get("/conversations", ArblargWeb.API.ExtChatController, :index)
      get("/conversations/:id", ArblargWeb.API.ExtChatController, :show)
      get("/conversations/:id/messages", ArblargWeb.API.ExtChatController, :messages)
    end
  end

  defmacro ext_api_write_routes do
    quote do
      post("/conversations/:id/messages", ArblargWeb.API.ExtChatController, :create)
    end
  end

  defmacro main_live_routes do
    quote do
      scope "/", alias: false do
        live("/chat", ArblargWeb.ChatLive.Index, :index)
        live("/chat/:conversation_id", ArblargWeb.ChatLive.Index, :conversation)
        live("/chat/join/:conversation_id", ArblargWeb.ChatLive.Index, :join)
      end
    end
  end
end
