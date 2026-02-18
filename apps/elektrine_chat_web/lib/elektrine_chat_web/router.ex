defmodule ElektrineChatWeb.Router do
  use ElektrineChatWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug ElektrineChatWeb.Plugs.APIAuth
    plug ElektrineChatWeb.Plugs.APIRateLimit
  end

  pipeline :messaging_federation do
    plug ElektrineChatWeb.Plugs.MessagingFederationAuth
  end

  scope "/", ElektrineChatWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end

  scope "/federation/messaging", ElektrineChatWeb do
    pipe_through [:api, :messaging_federation]

    post "/events", MessagingFederationController, :event
    post "/sync", MessagingFederationController, :sync
    get "/servers/:server_id/snapshot", MessagingFederationController, :snapshot
  end

  scope "/.well-known", ElektrineChatWeb do
    pipe_through :api

    get "/elektrine-messaging-federation", MessagingFederationController, :well_known
  end

  scope "/api", ElektrineChatWeb.API do
    pipe_through :api

    post "/auth/login", AuthController, :login
  end

  scope "/api", ElektrineChatWeb.API do
    pipe_through :api_authenticated

    post "/auth/logout", AuthController, :logout
    get "/auth/me", AuthController, :me

    get "/servers", ServerController, :index
    post "/servers", ServerController, :create
    get "/servers/:id", ServerController, :show
    post "/servers/:server_id/join", ServerController, :join
    post "/servers/:server_id/channels", ServerController, :create_channel

    get "/conversations", ConversationController, :index
    post "/conversations", ConversationController, :create
    get "/conversations/:id", ConversationController, :show
    put "/conversations/:id", ConversationController, :update
    delete "/conversations/:id", ConversationController, :delete

    post "/conversations/:conversation_id/join", ConversationController, :join
    post "/conversations/:conversation_id/leave", ConversationController, :leave
    post "/conversations/:conversation_id/read", ConversationController, :mark_read

    get "/conversations/:conversation_id/members", ConversationController, :members
    post "/conversations/:conversation_id/members", ConversationController, :add_member

    delete "/conversations/:conversation_id/members/:user_id",
           ConversationController,
           :remove_member

    get "/conversations/:conversation_id/messages", MessageController, :index
    post "/conversations/:conversation_id/messages", MessageController, :create
    put "/messages/:id", MessageController, :update
    delete "/messages/:id", MessageController, :delete

    post "/conversations/:conversation_id/upload", ConversationController, :upload_media

    post "/messages/:message_id/reactions", MessageController, :add_reaction
    delete "/messages/:message_id/reactions/:emoji", MessageController, :remove_reaction
  end
end
