defmodule ElektrineWeb.Routes.Social do
  @moduledoc false

  defmacro media_proxy_routes do
    quote do
      get("/:signature/:encoded_url", ElektrineSocialWeb.MediaProxyController, :proxy)
    end
  end

  defmacro discovery_routes do
    quote do
      scope "/.well-known", alias: false do
        pipe_through(:activitypub)
        get("/webfinger", ElektrineSocialWeb.WebFingerController, :webfinger)
        get("/host-meta", ElektrineSocialWeb.WebFingerController, :host_meta)
        get("/nodeinfo", ElektrineSocialWeb.NodeinfoController, :well_known)
      end

      scope "/nodeinfo", alias: false do
        pipe_through(:activitypub)
        get("/2.0", ElektrineSocialWeb.NodeinfoController, :nodeinfo_2_0)
        get("/2.1", ElektrineSocialWeb.NodeinfoController, :nodeinfo_2_1)
      end
    end
  end

  defmacro public_browser_routes do
    quote do
      scope "/", alias: false do
        get("/authorize_interaction", ElektrineSocialWeb.ExternalInteractionController, :show)

        get(
          "/activitypub/externalInteraction",
          ElektrineSocialWeb.ExternalInteractionController,
          :show
        )
      end
    end
  end

  defmacro activitypub_routes do
    quote do
      scope "/users/:username", alias: false do
        pipe_through(:activitypub)
        get("/", ElektrineSocialWeb.ActivityPubController, :actor)
        post("/inbox", ElektrineSocialWeb.ActivityPubController, :inbox)
        get("/outbox", ElektrineSocialWeb.ActivityPubController, :outbox)
        get("/followers", ElektrineSocialWeb.ActivityPubController, :followers)
        get("/following", ElektrineSocialWeb.ActivityPubController, :following)
        get("/statuses/:id", ElektrineSocialWeb.ActivityPubController, :object)
      end

      scope "/c/:name", alias: false do
        pipe_through(:activitypub)
        get("/", ElektrineSocialWeb.ActivityPubController, :community_actor)
        post("/inbox", ElektrineSocialWeb.ActivityPubController, :community_inbox)
        get("/outbox", ElektrineSocialWeb.ActivityPubController, :community_outbox)
        get("/followers", ElektrineSocialWeb.ActivityPubController, :community_followers)
        get("/moderators", ElektrineSocialWeb.ActivityPubController, :community_moderators)
        get("/posts/:id", ElektrineSocialWeb.ActivityPubController, :community_object)

        get(
          "/posts/:id/activity",
          ElektrineSocialWeb.ActivityPubController,
          :community_object_activity
        )
      end

      scope "/relay", alias: false do
        pipe_through(:activitypub)
        get("/", ElektrineSocialWeb.ActivityPubController, :relay_actor)
        post("/inbox", ElektrineSocialWeb.ActivityPubController, :inbox)
      end

      scope "/", alias: false do
        pipe_through(:activitypub)
        post("/inbox", ElektrineSocialWeb.ActivityPubController, :inbox)
      end

      scope "/tags", alias: false do
        pipe_through(:activitypub)
        get("/:name", ElektrineSocialWeb.ActivityPubController, :hashtag_collection)
      end
    end
  end

  defmacro mastodon_routes do
    quote do
      scope "/oauth", ElektrineSocialWeb.MastodonAPI do
        pipe_through(:api)
        post("/token", OAuthController, :token)
        post("/revoke", OAuthController, :revoke)
      end

      scope "/api/v1", ElektrineSocialWeb.MastodonAPI do
        pipe_through(:mastodon_api)
        post("/apps", AppController, :create)
        get("/instance", InstanceController, :show)
        get("/instance/peers", InstanceController, :peers)
        get("/instance/activity", InstanceController, :activity)
        get("/instance/rules", InstanceController, :rules)
        get("/accounts/lookup", AccountController, :lookup)
        get("/accounts/:id", AccountController, :show)
        get("/accounts/:id/statuses", AccountController, :statuses)
        get("/accounts/:id/followers", AccountController, :followers)
        get("/accounts/:id/following", AccountController, :following)
      end

      scope "/api/v2", ElektrineSocialWeb.MastodonAPI do
        pipe_through(:mastodon_api)
        get("/instance", InstanceController, :show_v2)
      end

      scope "/api/v1", ElektrineSocialWeb.MastodonAPI do
        pipe_through(:mastodon_api_authenticated)
        get("/apps/verify_credentials", AppController, :verify_credentials)
        get("/accounts/verify_credentials", AccountController, :verify_credentials)
        get("/accounts/relationships", AccountController, :relationships)
        post("/accounts/:id/follow", AccountController, :follow)
        post("/accounts/:id/unfollow", AccountController, :unfollow)
        post("/accounts/:id/block", AccountController, :block)
        post("/accounts/:id/unblock", AccountController, :unblock)
        post("/accounts/:id/mute", AccountController, :mute)
        post("/accounts/:id/unmute", AccountController, :unmute)
      end
    end
  end

  defmacro authenticated_api_routes do
    quote do
      get("/social/timeline", ElektrineSocialWeb.API.SocialController, :timeline)
      get("/social/timeline/public", ElektrineSocialWeb.API.SocialController, :public_timeline)
      get("/social/posts/:id", ElektrineSocialWeb.API.SocialController, :show_post)
      post("/social/posts", ElektrineSocialWeb.API.SocialController, :create_post)
      delete("/social/posts/:id", ElektrineSocialWeb.API.SocialController, :delete_post)
      post("/social/posts/:id/like", ElektrineSocialWeb.API.SocialController, :like_post)
      delete("/social/posts/:id/like", ElektrineSocialWeb.API.SocialController, :unlike_post)
      post("/social/posts/:id/repost", ElektrineSocialWeb.API.SocialController, :repost)
      delete("/social/posts/:id/repost", ElektrineSocialWeb.API.SocialController, :unrepost)

      get(
        "/social/posts/:post_id/comments",
        ElektrineSocialWeb.API.SocialController,
        :list_comments
      )

      post(
        "/social/posts/:post_id/comments",
        ElektrineSocialWeb.API.SocialController,
        :create_comment
      )

      delete("/social/comments/:id", ElektrineSocialWeb.API.SocialController, :delete_comment)
      post("/social/comments/:id/like", ElektrineSocialWeb.API.SocialController, :like_comment)

      delete(
        "/social/comments/:id/like",
        ElektrineSocialWeb.API.SocialController,
        :unlike_comment
      )

      get("/social/followers", ElektrineSocialWeb.API.SocialController, :list_followers)
      get("/social/following", ElektrineSocialWeb.API.SocialController, :list_following)
      get("/social/users/search", ElektrineSocialWeb.API.SocialController, :search_users)
      get("/social/users/:id", ElektrineSocialWeb.API.SocialController, :show_user)
      get("/social/users/:user_id/posts", ElektrineSocialWeb.API.SocialController, :user_posts)

      get(
        "/social/users/:user_id/followers",
        ElektrineSocialWeb.API.SocialController,
        :user_followers
      )

      get(
        "/social/users/:user_id/following",
        ElektrineSocialWeb.API.SocialController,
        :user_following
      )

      post("/social/users/:user_id/follow", ElektrineSocialWeb.API.SocialController, :follow_user)

      delete(
        "/social/users/:user_id/follow",
        ElektrineSocialWeb.API.SocialController,
        :unfollow_user
      )

      post("/social/users/:user_id/block", ElektrineSocialWeb.API.SocialController, :block_user)

      delete(
        "/social/users/:user_id/block",
        ElektrineSocialWeb.API.SocialController,
        :unblock_user
      )

      get(
        "/social/friend-requests",
        ElektrineSocialWeb.API.SocialController,
        :list_friend_requests
      )

      post(
        "/social/friend-requests/:id/accept",
        ElektrineSocialWeb.API.SocialController,
        :accept_friend_request
      )

      delete(
        "/social/friend-requests/:id",
        ElektrineSocialWeb.API.SocialController,
        :reject_friend_request
      )

      get("/social/communities", ElektrineSocialWeb.API.SocialController, :list_communities)
      get("/social/communities/mine", ElektrineSocialWeb.API.SocialController, :my_communities)

      get(
        "/social/communities/search",
        ElektrineSocialWeb.API.SocialController,
        :search_communities
      )

      get("/social/communities/:id", ElektrineSocialWeb.API.SocialController, :show_community)

      get(
        "/social/communities/:community_id/posts",
        ElektrineSocialWeb.API.SocialController,
        :community_posts
      )

      post("/social/communities", ElektrineSocialWeb.API.SocialController, :create_community)

      post(
        "/social/communities/:id/join",
        ElektrineSocialWeb.API.SocialController,
        :join_community
      )

      delete(
        "/social/communities/:id/join",
        ElektrineSocialWeb.API.SocialController,
        :leave_community
      )

      post("/social/upload", ElektrineSocialWeb.API.SocialController, :upload_media)
    end
  end

  defmacro ext_api_read_routes do
    quote do
      get("/feed", ElektrineSocialWeb.API.ExtSocialController, :feed)
      get("/posts/:id", ElektrineSocialWeb.API.ExtSocialController, :show)
      get("/users/:user_id/posts", ElektrineSocialWeb.API.ExtSocialController, :user_posts)
    end
  end

  defmacro ext_api_write_routes do
    quote do
      post("/posts", ElektrineSocialWeb.API.ExtSocialController, :create)
    end
  end

  defmacro main_live_routes do
    quote do
      scope "/", alias: false do
        live("/communities", ElektrineSocialWeb.DiscussionsLive.Index, :index)
        live("/communities/:name", ElektrineSocialWeb.DiscussionsLive.Community, :show)
        live("/communities/:name/settings", ElektrineSocialWeb.DiscussionsLive.Settings, :index)
        live("/communities/:name/post/:post_id", ElektrineSocialWeb.DiscussionsLive.Post, :show)

        live("/discussions", ElektrineSocialWeb.DiscussionsLive.Index, :index)
        live("/discussions/:name", ElektrineSocialWeb.DiscussionsLive.Community, :show)
        live("/discussions/:name/settings", ElektrineSocialWeb.DiscussionsLive.Settings, :index)
        live("/discussions/:name/post/:post_id", ElektrineSocialWeb.DiscussionsLive.Post, :show)

        live("/timeline", ElektrineSocialWeb.TimelineLive.Index, :index)
        live("/timeline/post/:id", ElektrineSocialWeb.TimelineLive.Post, :show)
        live("/post", ElektrineSocialWeb.RemotePostLive.Show, :show)
        live("/post/:post_id", ElektrineSocialWeb.RemotePostLive.Show, :show)
        live("/hashtag/:hashtag", ElektrineSocialWeb.HashtagLive.Show, :show)
        live("/lists", ElektrineSocialWeb.ListLive.Index, :index)
        live("/lists/:id", ElektrineSocialWeb.ListLive.Show, :show)
        live("/gallery", ElektrineSocialWeb.GalleryLive.Index, :index)
        live("/remote/:handle", ElektrineSocialWeb.RemoteUserLive.Show, :show)
        live("/remote/post", ElektrineSocialWeb.RemotePostLive.Show, :show)
        live("/remote/post/:post_id", ElektrineSocialWeb.RemotePostLive.Show, :show)
      end
    end
  end

  def path_prefixes do
    [
      "/authorize_interaction",
      "/activitypub",
      "/communities",
      "/discussions",
      "/timeline",
      "/hashtag",
      "/gallery",
      "/lists",
      "/remote",
      "/users/",
      "/c/",
      "/relay",
      "/inbox",
      "/tags",
      "/media_proxy",
      "/api/social",
      "/api/v1",
      "/api/v2",
      "/api/ext/v1/social",
      "/pripyat/communities"
    ]
  end

  def view_modules do
    [
      ElektrineSocialWeb.DiscussionsLive.Community,
      ElektrineSocialWeb.DiscussionsLive.Index,
      ElektrineSocialWeb.DiscussionsLive.Post,
      ElektrineSocialWeb.DiscussionsLive.Settings,
      ElektrineSocialWeb.GalleryLive.Index,
      ElektrineSocialWeb.HashtagLive.Show,
      ElektrineSocialWeb.ListLive.Index,
      ElektrineSocialWeb.ListLive.Show,
      ElektrineSocialWeb.RemotePostLive.Show,
      ElektrineSocialWeb.RemoteUserLive.Show,
      ElektrineSocialWeb.TimelineLive.Index,
      ElektrineSocialWeb.TimelineLive.Post
    ]
  end
end
