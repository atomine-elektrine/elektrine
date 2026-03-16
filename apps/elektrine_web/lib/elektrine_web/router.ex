defmodule ElektrineWeb.Router do
  use ElektrineWeb, :router

  import ElektrineWeb.UserAuth

  @default_profile_host_scope "*.#{Application.compile_env(:elektrine, :primary_domain, "elektrine.com")}"

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.TorAware)
    plug(:fetch_session)
    plug(ElektrineWeb.Plugs.StaticSitePlug)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ElektrineWeb.Layouts, :root})
    plug(:protect_from_forgery, with: :clear_session)
    plug(ElektrineWeb.Plugs.CSRFErrorHandler)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_user)
    plug(ElektrineWeb.Plugs.Locale)
    plug(ElektrineWeb.Plugs.TimezonePlug)
    plug(ElektrineWeb.Plugs.NotificationCount)
  end

  pipeline :profile do
    plug(:accepts, ["html"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.TorAware)
    plug(:fetch_session)
    plug(ElektrineWeb.Plugs.StaticSitePlug)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ElektrineWeb.Layouts, :root})
    plug(:protect_from_forgery, with: :clear_session)
    plug(ElektrineWeb.Plugs.CSRFErrorHandler)
    plug(:put_secure_browser_headers)
    plug(ElektrineWeb.Plugs.ProfileCSP)
    plug(:fetch_current_user)
    plug(ElektrineWeb.Plugs.Locale)
    plug(ElektrineWeb.Plugs.TimezonePlug)
    plug(ElektrineWeb.Plugs.NotificationCount)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.TorAware)
    plug(ElektrineWeb.Plugs.RequestTelemetry, scope: :api)
  end

  pipeline :api_rate_limited do
    plug(ElektrineWeb.Plugs.APIRateLimit)
  end

  pipeline :matrix_internal_api do
    plug(ElektrineWeb.Plugs.InternalAPIAuth,
      env_names: ["MATRIX_INTERNAL_API_KEY", "PHOENIX_API_KEY"]
    )
  end

  pipeline :mongooseim_internal_api do
    plug(ElektrineWeb.Plugs.InternalAPIAuth,
      env_names: ["MONGOOSEIM_API_KEY", "PHOENIX_API_KEY"]
    )
  end

  pipeline :caddy_internal_api do
    plug(ElektrineWeb.Plugs.InternalAPIAuth,
      env_names: ["CADDY_EDGE_API_KEY", "PHOENIX_API_KEY"],
      query_param: "token"
    )
  end

  # Browser-based JSON API pipeline
  # Used for AJAX calls from static pages that need session/CSRF but return JSON.
  # Examples: profile follow/unfollow, friend requests, followers/following lists
  pipeline :browser_api do
    plug(:accepts, ["json", "html"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.TorAware)
    plug(:fetch_session)
    plug(:protect_from_forgery, with: :clear_session)
    plug(ElektrineWeb.Plugs.CSRFErrorHandler)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_user)
  end

  pipeline :api_authenticated do
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.APIAuth)
    plug(ElektrineWeb.Plugs.APIRateLimit)
    plug(ElektrineWeb.Plugs.RequestTelemetry, scope: :api)
  end

  pipeline :api_pat_authenticated do
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.PATAuth)
    plug(ElektrineWeb.Plugs.APIRateLimit)
    plug(ElektrineWeb.Plugs.RequestTelemetry, scope: :api)
  end

  pipeline :api_vault_authenticated do
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.PATAuth, allow_api_token: true)
    plug(ElektrineWeb.Plugs.APIRateLimit)
    plug(ElektrineWeb.Plugs.RequestTelemetry, scope: :api)
  end

  pipeline :api_pat_search_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth,
      scopes: [
        "read:account",
        "read:email",
        "read:chat",
        "read:social",
        "read:contacts",
        "read:calendar"
      ],
      any: true
    )
  end

  pipeline :api_pat_calendar_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["read:calendar", "write:calendar"], any: true)
  end

  pipeline :api_pat_calendar_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:calendar"])
  end

  pipeline :api_pat_email_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["read:email", "write:email"], any: true)
  end

  pipeline :api_pat_email_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:email"])
  end

  pipeline :api_pat_chat_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["read:chat", "write:chat"], any: true)
  end

  pipeline :api_pat_chat_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:chat"])
  end

  pipeline :api_pat_social_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["read:social", "write:social"], any: true)
  end

  pipeline :api_pat_social_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:social"])
  end

  pipeline :api_pat_contacts_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["read:contacts", "write:contacts"], any: true)
  end

  pipeline :api_pat_account_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["read:account", "write:account"], any: true)
  end

  pipeline :api_pat_account_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:account"])
  end

  pipeline :api_pat_vault_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth,
      scopes: ["read:vault", "write:vault"],
      any: true,
      allow_api_token: true
    )
  end

  pipeline :api_pat_vault_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:vault"], allow_api_token: true)
  end

  pipeline :api_pat_export_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["export"])
  end

  pipeline :api_pat_webhook_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["webhook"])
  end

  pipeline :activitypub do
    # Custom plug that accepts any content type for ActivityPub federation
    plug(ElektrineWeb.Plugs.ActivityPubAccept)
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.ActivityPubRateLimit)
    # HTTP Signature validation (assigns :valid_signature and :signature_actor)
    plug(ElektrineWeb.Plugs.HTTPSignaturePlug)
    # Enforce signatures when authorized fetch mode is enabled
    plug(ElektrineWeb.Plugs.EnsureHTTPSignaturePlug)
  end

  pipeline :messaging_federation do
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.MessagingFederationAuth)
    plug(ElektrineWeb.Plugs.APIRateLimit)
  end

  pipeline :dav do
    # CalDAV/CardDAV pipeline
    plug(:accepts, ["xml", "text", "json"])
    plug(ElektrineWeb.Plugs.WebDAVMethodOverride)
    plug(ElektrineWeb.Plugs.DAVAuth)
    plug(ElektrineWeb.Plugs.DAVRateLimit)
    plug(ElektrineWeb.Plugs.RequestTelemetry, scope: :dav)
  end

  pipeline :dav_discovery do
    # DAV discovery (no auth required for redirect)
    plug(:accepts, ["xml", "text", "json"])
    plug(ElektrineWeb.Plugs.WebDAVMethodOverride)
    plug(ElektrineWeb.Plugs.RequestTelemetry, scope: :dav)
  end

  pipeline :jmap do
    # JMAP pipeline (RFC 8620, RFC 8621)
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.TorAware)
    plug(ElektrineWeb.Plugs.OptionalDelegate, module: ElektrineWeb.Plugs.JMAPAuth)
    plug(ElektrineWeb.Plugs.APIRateLimit)
  end

  pipeline :jmap_discovery do
    # JMAP discovery (authenticated)
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.OptionalDelegate, module: ElektrineWeb.Plugs.JMAPAuth)
  end

  pipeline :autoconfig do
    # Email client autodiscovery (no auth)
    plug(:accepts, ["xml", "html", "json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(:put_secure_browser_headers)
  end

  pipeline :mastodon_api do
    # Mastodon-compatible API pipeline
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.MastodonAPIAuth, required: false)
  end

  pipeline :mastodon_api_authenticated do
    # Mastodon-compatible API pipeline (authentication required)
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.MastodonAPIAuth, required: true)
  end

  # Health check endpoint for Fly.io (no auth required)
  scope "/", ElektrineWeb do
    pipe_through(:api)

    get("/health", HealthController, :check)
  end

  # Stripe webhook (no auth, signature verified in controller)
  scope "/webhook", ElektrineWeb do
    pipe_through(:api)

    post("/stripe", StripeWebhookController, :webhook)
  end

  # Matrix internal auth compatibility endpoint (for Synapse REST auth provider)
  scope "/_matrix-internal/identity/v1", ElektrineWeb do
    pipe_through([:api, :matrix_internal_api, :api_rate_limited])

    post("/check_credentials", MatrixInternalAuthController, :check_credentials)
  end

  # MongooseIM internal auth compatibility endpoint
  scope "/_mongooseim/identity/v1", ElektrineWeb do
    pipe_through([:api, :mongooseim_internal_api, :api_rate_limited])

    post("/check_credentials", MongooseIMAuthController, :check_credentials)
    post("/check_password", MongooseIMAuthController, :check_password)
    get("/user_exists", MongooseIMAuthController, :user_exists)
    post("/user_exists", MongooseIMAuthController, :user_exists)
  end

  # Internal Caddy on-demand TLS allowlist endpoint.
  # This stays on the private/origin app hostname and should be called only by the Caddy edge.
  scope "/_edge/tls/v1", ElektrineWeb do
    pipe_through([:api, :caddy_internal_api])

    get("/allow", CaddyTLSController, :allow)
  end

  # Media proxy for federation privacy (no auth required)
  scope "/media_proxy", ElektrineWeb do
    pipe_through(:api)

    get("/:signature/:encoded_url", MediaProxyController, :proxy)
  end

  scope "/api", ElektrineWeb do
    pipe_through([ElektrineWeb.Plugs.RequirePlatformModule])

    get("/private-attachments/:token", PrivateAttachmentController, :show)
  end

  # Lightweight signed messaging federation endpoints (instance-to-instance)
  scope "/_arblarg", ElektrineWeb do
    pipe_through([:api, :messaging_federation])

    post("/events", MessagingFederationController, :event)
    post("/events/batch", MessagingFederationController, :event_batch)
    post("/ephemeral", MessagingFederationController, :ephemeral)
    post("/sync", MessagingFederationController, :sync)
    get("/streams/events", MessagingFederationController, :stream_events)
    get("/servers/:server_id/snapshot", MessagingFederationController, :snapshot)
  end

  scope "/_arblarg", ElektrineWeb do
    pipe_through([:messaging_federation])

    get("/session", MessagingFederationController, :session_websocket)
  end

  # Public messaging federation server directory for cross-instance discovery
  scope "/_arblarg", ElektrineWeb do
    pipe_through(:api)

    get("/servers/public", MessagingFederationController, :public_servers)
  end

  # Public Arblarg schema registry
  scope "/_arblarg", ElektrineWeb do
    pipe_through(:api)

    get("/profiles", MessagingFederationController, :profiles)
    get("/:version/schemas/:name", MessagingFederationController, :schema)
  end

  # Public well-known discovery for Arblarg messaging federation identity/capabilities
  scope "/.well-known", ElektrineWeb do
    pipe_through(:api)

    get("/_arblarg", MessagingFederationController, :well_known)
    get("/_arblarg/:version", MessagingFederationController, :well_known_versioned)
  end

  # Matrix well-known discovery/delegation endpoints
  scope "/.well-known/matrix", ElektrineWeb do
    pipe_through(:api)

    get("/server", MatrixWellKnownController, :server)
    get("/client", MatrixWellKnownController, :client)
  end

  # Email client autodiscovery
  scope "/.well-known/autoconfig/mail", ElektrineWeb do
    pipe_through(:autoconfig)

    get("/config-v1.1.xml", AutoconfigController, :mozilla_autoconfig)
  end

  # Alternative autoconfig paths (for autoconfig.domain.com subdomain)
  scope "/mail", ElektrineWeb do
    pipe_through(:autoconfig)

    get("/config-v1.1.xml", AutoconfigController, :mozilla_autoconfig)
  end

  # Microsoft Autodiscover
  scope "/autodiscover", ElektrineWeb do
    pipe_through(:autoconfig)

    post("/autodiscover.xml", AutoconfigController, :microsoft_autodiscover)
    # Some clients use GET
    get("/autodiscover.xml", AutoconfigController, :mozilla_autoconfig)
  end

  # Apple mobileconfig download
  scope "/", ElektrineWeb do
    pipe_through(:autoconfig)

    get("/mail.mobileconfig", AutoconfigController, :apple_mobileconfig)
  end

  # CalDAV/CardDAV discovery
  scope "/.well-known", ElektrineWeb do
    pipe_through(:dav_discovery)

    get("/caldav", DAVController, :caldav_discovery)
    get("/carddav", DAVController, :carddav_discovery)
  end

  # WKD (Web Key Directory) for PGP public key discovery
  scope "/.well-known/openpgpkey", ElektrineWeb do
    pipe_through(:api)

    # Direct method: /.well-known/openpgpkey/hu/{hash}
    get("/hu/:hash", WKDController, :get_key)
    # Policy file
    get("/policy", WKDController, :policy)
  end

  # CalDAV routes
  scope "/calendars", ElektrineWeb.DAV do
    pipe_through(:dav)

    match(:propfind, "/:username", CalendarController, :propfind_home)
    match(:propfind, "/:username/:calendar_id", CalendarController, :propfind_calendar)
    match(:report, "/:username/:calendar_id", CalendarController, :report)
    match(:mkcalendar, "/:username/:calendar_id", CalendarController, :mkcalendar)
    get("/:username/:calendar_id/:event_uid", CalendarController, :get_event)
    put("/:username/:calendar_id/:event_uid", CalendarController, :put_event)
    delete("/:username/:calendar_id/:event_uid", CalendarController, :delete_event)
  end

  # CardDAV routes
  scope "/addressbooks", ElektrineWeb.DAV do
    pipe_through(:dav)

    match(:propfind, "/:username", AddressBookController, :propfind_home)
    match(:propfind, "/:username/contacts", AddressBookController, :propfind_addressbook)
    match(:report, "/:username/contacts", AddressBookController, :report)
    get("/:username/contacts/:contact_uid", AddressBookController, :get_contact)
    put("/:username/contacts/:contact_uid", AddressBookController, :put_contact)
    delete("/:username/contacts/:contact_uid", AddressBookController, :delete_contact)
  end

  # Principal resources for DAV
  scope "/principals/users", ElektrineWeb.DAV do
    pipe_through(:dav)

    match(:propfind, "/:username", PrincipalController, :propfind)
  end

  # JMAP discovery (RFC 8620)
  scope "/.well-known", ElektrineWeb.JMAP do
    pipe_through(:jmap_discovery)

    get("/jmap", SessionController, :session)
  end

  # JMAP API (RFC 8620, RFC 8621)
  scope "/jmap", ElektrineWeb.JMAP do
    pipe_through(:jmap)

    post("/", APIController, :api)
    get("/eventsource", EventSourceController, :eventsource)
    get("/download/:account_id/:blob_id/:name", BlobController, :download)
    post("/upload/:account_id", BlobController, :upload)
  end

  # ActivityPub federation routes
  scope "/.well-known", ElektrineWeb do
    pipe_through(:activitypub)

    get("/webfinger", WebFingerController, :webfinger)
    get("/host-meta", WebFingerController, :host_meta)
    get("/nodeinfo", NodeinfoController, :well_known)
  end

  # Nodeinfo endpoints (outside .well-known scope)
  scope "/nodeinfo", ElektrineWeb do
    pipe_through(:activitypub)

    get("/2.0", NodeinfoController, :nodeinfo_2_0)
    get("/2.1", NodeinfoController, :nodeinfo_2_1)
  end

  # Routes that don't require authentication (MOVED BEFORE ActivityPub to prioritize browser requests)
  scope "/", ElektrineWeb do
    pipe_through(:browser)

    # SEO
    get("/sitemap.xml", SitemapController, :index)
    get("/robots.txt", SitemapController, :robots)

    # ActivityPub external interaction compatibility (Lemmy/Mastodon clients)
    get("/authorize_interaction", ExternalInteractionController, :show)
    get("/activitypub/externalInteraction", ExternalInteractionController, :show)

    # Temporary email routes disabled
    # Guest temporary mail system has been disabled for security

    # Link click tracking and redirect
    get("/l/:id", LinkController, :click)

    # Unsubscribe routes (RFC 8058 support) - POST routes stay as controllers
    post("/unsubscribe/:token", UnsubscribeController, :one_click)
    post("/unsubscribe/confirm/:token", UnsubscribeController, :confirm)
    post("/resubscribe", UnsubscribeController, :resubscribe)
  end

  # Routes that are specifically for unauthenticated users
  scope "/", ElektrineWeb do
    pipe_through([:browser, :redirect_if_user_is_authenticated])

    # LiveView routes in their own session for consistent behavior
    live_session :auth,
      on_mount: [{ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}] do
      live("/register", AuthLive.Register, :new)
      live("/login", AuthLive.Login, :new)
      live("/password/reset", AuthLive.PasswordReset, :new)
      live("/password/reset/:token", AuthLive.PasswordResetEdit, :edit)
    end

    # Controller routes for form submissions
    post("/register", UserRegistrationController, :create)
    post("/register/purchase", RegistrationPaymentController, :create)
    get("/captcha", CaptchaController, :show)
    post("/login", UserSessionController, :create)
    post("/password/reset", PasswordResetController, :create)
    put("/password/reset/:token", PasswordResetController, :update)
  end

  scope "/", ElektrineWeb do
    pipe_through(:browser)

    get("/register/purchase/success", RegistrationPaymentController, :show)
  end

  # Passkey authentication route (must be before authentication redirect)
  scope "/", ElektrineWeb do
    pipe_through(:browser)

    post("/passkey/authenticate", PasskeyController, :authenticate)
  end

  # Recovery email verification (accessible by both logged-in and logged-out users)
  scope "/", ElektrineWeb do
    pipe_through(:browser)

    get("/verify-recovery-email", RecoveryEmailController, :verify)
  end

  # Two-factor authentication routes (accessible during login process)
  scope "/", ElektrineWeb do
    pipe_through(:browser)

    live_session :two_factor,
      on_mount: [{ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}] do
      live("/two_factor", AuthLive.TwoFactor, :new)
    end

    post("/two_factor", TwoFactorController, :create)
  end

  # ActivityPub user routes (AFTER LiveView routes so browser requests hit LiveView first)
  scope "/users/:username", ElektrineWeb do
    pipe_through(:activitypub)

    get("/", ActivityPubController, :actor)
    post("/inbox", ActivityPubController, :inbox)
    get("/outbox", ActivityPubController, :outbox)
    get("/followers", ActivityPubController, :followers)
    get("/following", ActivityPubController, :following)
    get("/statuses/:id", ActivityPubController, :object)
  end

  # ActivityPub community (Group) routes - Use /c/ prefix to avoid conflict with /communities/ LiveView
  scope "/c/:name", ElektrineWeb do
    pipe_through(:activitypub)

    get("/", ActivityPubController, :community_actor)
    post("/inbox", ActivityPubController, :community_inbox)
    get("/outbox", ActivityPubController, :community_outbox)
    get("/followers", ActivityPubController, :community_followers)
    get("/moderators", ActivityPubController, :community_moderators)
    get("/posts/:id", ActivityPubController, :community_object)
    get("/posts/:id/activity", ActivityPubController, :community_object_activity)
  end

  # Relay actor inbox (for receiving Accept/Reject from relays)
  scope "/relay", ElektrineWeb do
    pipe_through(:activitypub)

    get("/", ActivityPubController, :relay_actor)
    post("/inbox", ActivityPubController, :inbox)
  end

  # Shared inbox for federation
  scope "/", ElektrineWeb do
    pipe_through(:activitypub)

    post("/inbox", ActivityPubController, :inbox)
  end

  # Hashtag collection endpoint for federation
  scope "/tags", ElektrineWeb do
    pipe_through(:activitypub)

    get("/:name", ActivityPubController, :hashtag_collection)
  end

  # API routes for OAuth and other JSON endpoints
  scope "/", ElektrineWeb do
    pipe_through(:api)
  end

  # Routes that require authentication
  scope "/", ElektrineWeb do
    pipe_through([:browser, :require_authenticated_user])

    # Onboarding (special live_session - no onboarding redirect to avoid loop)
    live_session :onboarding,
      on_mount: [
        {ElektrineWeb.Live.AuthHooks, :require_authenticated_user},
        {ElektrineWeb.Live.Hooks.NotificationCountHook, :default},
        {ElektrineWeb.Live.Hooks.TimezoneHook, :default}
      ] do
      live("/onboarding", OnboardingLive)
    end

    # NOTE: /account LiveView moved to :main live_session for seamless navigation
    # Auth is enforced by on_mount hook in UserSettingsLive
    # Settings pages - GET as LiveViews, POST/PUT/DELETE as controllers
    put("/account/password", UserSettingsController, :update_password)
    get("/account/two_factor/qr_code", UserSettingsController, :two_factor_qr_code)
    post("/account/two_factor/enable", UserSettingsController, :two_factor_enable)
    post("/account/two_factor/disable", UserSettingsController, :two_factor_disable)
    post("/account/two_factor/regenerate", UserSettingsController, :two_factor_regenerate_codes)
    delete("/account", UserSettingsController, :confirm_delete)

    # Announcement dismissal
    post("/announcements/:id/dismiss", UserSettingsController, :dismiss_announcement)

    # User status update
    post("/account/status", UserSettingsController, :set_status)

    # Email attachment downloads
    get(
      "/email/message/:message_id/attachment/:attachment_id/download",
      AttachmentController,
      :download
    )

    # NOTE: All LiveView routes moved to single public_content live_session at end of router
    # for seamless navigation. Auth is enforced by pipe_through :require_authenticated_user

    # Email controller routes
    delete("/email/:id", EmailController, :delete)
    get("/email/:id/print", EmailController, :print)
    get("/email/:id/download_eml", EmailController, :download_eml)
    get("/email/:id/iframe_content", EmailController, :iframe_content)
    get("/email/export/download/:id", EmailController, :download_export)
  end

  # Impersonation exit route (must be accessible while acting as a non-admin user)
  scope "/pripyat", ElektrineWeb do
    pipe_through([
      :browser,
      :require_authenticated_user,
      ElektrineWeb.Plugs.RequireElektrineDomain
    ])

    get("/stop-impersonation", Admin.UsersController, :stop_impersonation)
    post("/stop-impersonation", Admin.UsersController, :stop_impersonation)
  end

  # Admin security routes (elevation + per-action passkey re-sign)
  scope "/pripyat/security", ElektrineWeb do
    pipe_through([
      :browser,
      :require_authenticated_user,
      :require_admin_user,
      ElektrineWeb.Plugs.RequireElektrineDomain
    ])

    get("/elevate", Admin.SecurityController, :elevate)
    post("/elevate/start", Admin.SecurityController, :start_elevation)
    post("/elevate/finish", Admin.SecurityController, :finish_elevation)
    post("/action/start", Admin.SecurityController, :start_action)
    post("/action/finish", Admin.SecurityController, :finish_action)
  end

  # Admin routes - require admin privileges and elektrine.com domain
  scope "/pripyat", ElektrineWeb do
    pipe_through([
      :browser,
      :require_admin_access,
      ElektrineWeb.Plugs.RequireElektrineDomain
    ])

    # Main dashboard
    get("/", AdminController, :dashboard)

    # User management (Admin.UsersController)
    get("/users", Admin.UsersController, :index)
    get("/users/new", Admin.UsersController, :new)
    post("/users", Admin.UsersController, :create)
    get("/users/:id/edit", Admin.UsersController, :edit)
    put("/users/:id", Admin.UsersController, :update)
    get("/users/:id/ban", Admin.UsersController, :ban)
    post("/users/:id/ban", Admin.UsersController, :confirm_ban)
    post("/users/:id/unban", Admin.UsersController, :unban)
    post("/users/:id/suspend", Admin.UsersController, :suspend)
    post("/users/:id/unsuspend", Admin.UsersController, :unsuspend)
    post("/users/:id/impersonate", Admin.UsersController, :impersonate)
    delete("/users/:id", Admin.UsersController, :delete)
    delete("/users/:user_id/aliases/:alias_id", Admin.UsersController, :delete_user_alias)
    get("/multi-accounts", Admin.UsersController, :multi_accounts)
    get("/lookup-ip/:ip", Admin.UsersController, :lookup_ip)
    get("/account-lookup", Admin.UsersController, :account_lookup)
    post("/account-lookup", Admin.UsersController, :search_accounts)
    post("/users/:id/reset-password", Admin.UsersController, :reset_user_password)
    post("/users/:id/reset-2fa", Admin.UsersController, :reset_user_2fa)

    # Alias management (Admin.AliasesController)
    get("/aliases", Admin.AliasesController, :index)
    post("/aliases/:id/toggle", Admin.AliasesController, :toggle)
    delete("/aliases/:id", Admin.AliasesController, :delete)
    get("/forwarded-messages", Admin.AliasesController, :forwarded_messages)

    # Mailbox management (Admin.MailboxesController)
    get("/mailboxes", Admin.MailboxesController, :index)
    delete("/mailboxes/:id", Admin.MailboxesController, :delete)
    get("/custom-domains", Admin.CustomDomainsController, :index)

    # Message management (Admin.MessagesController)
    get("/messages", Admin.MessagesController, :index)
    get("/messages/:id/view", Admin.MessagesController, :view)
    get("/messages/:id/raw", Admin.MessagesController, :view_raw)
    get("/users/:id/messages", Admin.MessagesController, :user_messages)
    get("/users/:user_id/messages/:id", Admin.MessagesController, :view_user_message)
    get("/users/:user_id/messages/:id/raw", Admin.MessagesController, :view_user_message_raw)
    get("/messages/:id/iframe", Admin.MessagesController, :iframe)

    # Arblarg chat message management (Admin.ChatMessagesController)
    get("/arblarg/messages", Admin.ChatMessagesController, :index)
    get("/arblarg/messages/:id/view", Admin.ChatMessagesController, :view)
    get("/arblarg/messages/:id/raw", Admin.ChatMessagesController, :view_raw)

    # Monitoring (Admin.MonitoringController)
    get("/active-users", Admin.MonitoringController, :active_users)
    get("/imap-users", Admin.MonitoringController, :imap_users)
    get("/pop3-users", Admin.MonitoringController, :pop3_users)
    get("/2fa-status", Admin.MonitoringController, :two_factor_status)
    get("/system-health", Admin.MonitoringController, :system_health)

    # Deletion requests (Admin.DeletionRequestsController)
    get("/deletion-requests", Admin.DeletionRequestsController, :index)
    get("/deletion-requests/:id", Admin.DeletionRequestsController, :show)
    post("/deletion-requests/:id/approve", Admin.DeletionRequestsController, :approve)
    post("/deletion-requests/:id/deny", Admin.DeletionRequestsController, :deny)

    # Invite codes management (Admin.InviteCodesController)
    get("/invite-codes", Admin.InviteCodesController, :index)
    get("/invite-codes/new", Admin.InviteCodesController, :new)
    post("/invite-codes", Admin.InviteCodesController, :create)
    get("/invite-codes/:id/edit", Admin.InviteCodesController, :edit)
    put("/invite-codes/:id", Admin.InviteCodesController, :update)
    delete("/invite-codes/:id", Admin.InviteCodesController, :delete)
    post("/invite-codes/toggle-system", Admin.InviteCodesController, :toggle_system)

    post(
      "/invite-codes/self-service-trust-level",
      Admin.InviteCodesController,
      :update_self_service_trust_level
    )

    # Platform updates management
    get("/updates", AdminUpdatesController, :index)
    get("/updates/new", AdminUpdatesController, :new)
    post("/updates", AdminUpdatesController, :create)
    delete("/updates/:id", AdminUpdatesController, :delete)

    # Audit logs
    get("/audit-logs", AdminAuditLogsController, :index)

    # Announcements management (Admin.AnnouncementsController)
    get("/announcements", Admin.AnnouncementsController, :index)
    get("/announcements/new", Admin.AnnouncementsController, :new)
    post("/announcements", Admin.AnnouncementsController, :create)
    get("/announcements/:id/edit", Admin.AnnouncementsController, :edit)
    put("/announcements/:id", Admin.AnnouncementsController, :update)
    delete("/announcements/:id", Admin.AnnouncementsController, :delete)

    # Community management (Admin.CommunitiesController)
    get("/communities", Admin.CommunitiesController, :index)
    get("/communities/:id", Admin.CommunitiesController, :show)
    delete("/communities/:id", Admin.CommunitiesController, :delete)
    post("/communities/:id/toggle", Admin.CommunitiesController, :toggle)
    post("/communities/:id/remove-member", Admin.CommunitiesController, :remove_member)

    # Content viewing and moderation (Admin.ModerationController)
    get("/content-moderation", Admin.ModerationController, :content)
    post("/content-moderation/delete", Admin.ModerationController, :delete_content)

    # Unsubscribe statistics (Admin.ModerationController)
    get("/unsubscribe-stats", Admin.ModerationController, :unsubscribe_stats)

    # Subscription products management (Admin.SubscriptionsController)
    get("/subscriptions", Admin.SubscriptionsController, :index)
    get("/subscriptions/new", Admin.SubscriptionsController, :new)
    post("/subscriptions", Admin.SubscriptionsController, :create)
    get("/subscriptions/:id/edit", Admin.SubscriptionsController, :edit)
    put("/subscriptions/:id", Admin.SubscriptionsController, :update)
    delete("/subscriptions/:id", Admin.SubscriptionsController, :delete)
    post("/subscriptions/:id/toggle", Admin.SubscriptionsController, :toggle)

    # VPN management (Admin.VPNController)
    get("/vpn", Admin.VPNController, :dashboard)
    get("/vpn/servers/new", Admin.VPNController, :new_server)
    post("/vpn/servers", Admin.VPNController, :create_server)
    get("/vpn/servers/:id/edit", Admin.VPNController, :edit_server)
    get("/vpn/servers/:id/confirm-delete", Admin.VPNController, :confirm_delete_server)
    put("/vpn/servers/:id", Admin.VPNController, :update_server)
    delete("/vpn/servers/:id", Admin.VPNController, :delete_server)
    get("/vpn/users", Admin.VPNController, :users)
    get("/vpn/users/:id/edit", Admin.VPNController, :edit_user_config)
    put("/vpn/users/:id", Admin.VPNController, :update_user_config)
    post("/vpn/users/:id/reset-quota", Admin.VPNController, :reset_user_quota)
  end

  # Admin LiveView routes - wrapped in live_session for authentication and domain restriction
  scope "/pripyat", ElektrineWeb do
    pipe_through([:browser, :require_admin_access, ElektrineWeb.Plugs.RequireElektrineDomain])

    live_session :admin,
      on_mount: [
        {ElektrineWeb.Live.AuthHooks, :require_admin_user},
        {ElektrineWeb.Live.Hooks.NotificationCountHook, :default},
        {ElektrineWeb.Live.Hooks.TimezoneHook, :default},
        {ElektrineWeb.Live.Hooks.PresenceHook, :default}
      ],
      root_layout: {ElektrineWeb.Layouts, :root},
      layout: {ElektrineWeb.Layouts, :admin} do
      # Reports dashboard
      live("/reports", AdminLive.ReportsDashboard, :index)

      # Badge management
      live("/badges", AdminLive.BadgeManagement, :index)

      # Federation management
      live("/federation", AdminLive.Federation, :index)

      # Messaging federation management
      live("/messaging-federation", AdminLive.MessagingFederation, :index)

      # Bluesky bridge management
      live("/bluesky-bridge", AdminLive.BlueskyBridge, :index)

      # Relay management
      live("/relays", AdminLive.Relays, :index)

      # Custom emoji management
      live("/emojis", AdminLive.Emojis, :index)
      live("/emojis/new", AdminLive.Emojis, :new)
      live("/emojis/:id/edit", AdminLive.Emojis, :edit)
    end
  end

  # Routes for all users (authenticated or not)
  scope "/", ElektrineWeb do
    pipe_through([:browser])

    delete("/logout", UserSessionController, :delete)
    get("/locale/switch", LocaleController, :switch)
  end

  # ===========================================================================
  # Mastodon-compatible API routes
  # ===========================================================================
  # These routes provide compatibility with Mastodon third-party clients
  # like Tusky, Ivory, Ice Cubes, Elk, etc.

  # OAuth token endpoints (no auth required for token exchange)
  scope "/oauth", ElektrineWeb.MastodonAPI do
    pipe_through(:api)

    post("/token", OAuthController, :token)
    post("/revoke", OAuthController, :revoke)
  end

  # Mastodon API v1 - Public endpoints (no auth required)
  scope "/api/v1", ElektrineWeb.MastodonAPI do
    pipe_through(:mastodon_api)

    # App registration
    post("/apps", AppController, :create)

    # Instance info
    get("/instance", InstanceController, :show)
    get("/instance/peers", InstanceController, :peers)
    get("/instance/activity", InstanceController, :activity)
    get("/instance/rules", InstanceController, :rules)

    # Account endpoints (public, but auth optional for relationships)
    get("/accounts/lookup", AccountController, :lookup)
    get("/accounts/:id", AccountController, :show)
    get("/accounts/:id/statuses", AccountController, :statuses)
    get("/accounts/:id/followers", AccountController, :followers)
    get("/accounts/:id/following", AccountController, :following)
  end

  # Mastodon API v2 - Public endpoints
  scope "/api/v2", ElektrineWeb.MastodonAPI do
    pipe_through(:mastodon_api)

    get("/instance", InstanceController, :show_v2)
  end

  # Mastodon API v1 - Authenticated endpoints
  scope "/api/v1", ElektrineWeb.MastodonAPI do
    pipe_through(:mastodon_api_authenticated)

    # App credentials verification
    get("/apps/verify_credentials", AppController, :verify_credentials)

    # Account endpoints (authenticated)
    get("/accounts/verify_credentials", AccountController, :verify_credentials)
    get("/accounts/relationships", AccountController, :relationships)
    post("/accounts/:id/follow", AccountController, :follow)
    post("/accounts/:id/unfollow", AccountController, :unfollow)
    post("/accounts/:id/block", AccountController, :block)
    post("/accounts/:id/unblock", AccountController, :unblock)
    post("/accounts/:id/mute", AccountController, :mute)
    post("/accounts/:id/unmute", AccountController, :unmute)
  end

  # Other scopes may use custom stacks.
  scope "/api", ElektrineWeb do
    pipe_through(:api)

    # Email API endpoints
    post("/haraka/inbound", HarakaWebhookController, :create)
    post("/haraka/verify-recipient", HarakaWebhookController, :verify_recipient)
    post("/haraka/auth", HarakaWebhookController, :auth)
    get("/haraka/domains", HarakaWebhookController, :domains)

    # VPN API endpoints (called by WireGuard servers)
    post("/vpn/register", VPNAPIController, :auto_register)
    get("/vpn/:server_id/peers", VPNAPIController, :get_peers)
    post("/vpn/:server_id/stats", VPNAPIController, :update_stats)
    post("/vpn/:server_id/heartbeat", VPNAPIController, :heartbeat)
    post("/vpn/:server_id/connection", VPNAPIController, :log_connection)
    post("/vpn/:server_id/register-key", VPNAPIController, :register_key)
    post("/vpn/:server_id/check-peer", VPNAPIController, :check_peer)
  end

  # Mobile app authentication - Always available for VPN access
  scope "/api", ElektrineWeb.API do
    pipe_through(:api)

    # Authentication endpoints (no auth required)
    post("/auth/login", AuthController, :login)
  end

  # Mobile app authenticated endpoints - Always available for VPN
  scope "/api", ElektrineWeb.API do
    pipe_through(:api_authenticated)

    # Auth endpoints (require token)
    post("/auth/logout", AuthController, :logout)
    get("/auth/me", AuthController, :me)

    # Settings endpoints
    get("/settings", SettingsController, :index)
    put("/settings/profile", SettingsController, :update_profile)
    put("/settings/notifications", SettingsController, :update_notifications)
    put("/settings/password", SettingsController, :update_password)
    post("/settings/bluesky/enable", SettingsController, :enable_bluesky_managed)

    # VPN endpoints
    get("/vpn/servers", VPNController, :index)
    get("/vpn/configs", VPNController, :list_configs)
    get("/vpn/configs/:id", VPNController, :show_config)
    post("/vpn/configs", VPNController, :create_config)
    delete("/vpn/configs/:id", VPNController, :delete_config)

    # Email API endpoints
    get("/emails", EmailController, :index)
    get("/emails/search", EmailController, :search)
    get("/emails/counts", EmailController, :counts)
    post("/emails/bulk", EmailController, :bulk_action)
    get("/emails/:id", EmailController, :show)
    get("/emails/:id/attachments", EmailController, :list_attachments)
    get("/emails/:id/attachments/:attachment_id", EmailController, :attachment)
    post("/emails/send", EmailController, :send_email)
    put("/emails/:id", EmailController, :update)
    put("/emails/:id/category", EmailController, :update_category)
    put("/emails/:id/reply-later", EmailController, :set_reply_later)
    delete("/emails/:id", EmailController, :delete)

    # Alias management
    get("/aliases", AliasController, :index)
    post("/aliases", AliasController, :create)
    get("/aliases/:id", AliasController, :show)
    put("/aliases/:id", AliasController, :update)
    delete("/aliases/:id", AliasController, :delete)

    # Mailbox info
    get("/mailbox", MailboxController, :show)
    get("/mailbox/stats", MailboxController, :stats)

    # Device registration for push notifications
    get("/devices", DeviceController, :index)
    post("/devices", DeviceController, :create)
    delete("/devices/:token", DeviceController, :delete)

    # Notifications
    get("/notifications", NotificationController, :index)
    post("/notifications/:id/read", NotificationController, :mark_read)
    post("/notifications/read-all", NotificationController, :mark_all_read)
    delete("/notifications/:id", NotificationController, :dismiss)

    # Chat/Messaging API
    get("/servers", ServerController, :index)
    post("/servers", ServerController, :create)
    get("/servers/:id", ServerController, :show)
    post("/servers/:server_id/join", ServerController, :join)
    post("/servers/:server_id/channels", ServerController, :create_channel)

    get("/conversations", ConversationController, :index)
    post("/conversations", ConversationController, :create)
    get("/conversations/:id", ConversationController, :show)
    put("/conversations/:id", ConversationController, :update)
    delete("/conversations/:id", ConversationController, :delete)

    # Conversation actions
    post("/conversations/:conversation_id/join", ConversationController, :join)
    post("/conversations/:conversation_id/leave", ConversationController, :leave)
    post("/conversations/:conversation_id/read", ConversationController, :mark_read)

    # Conversation members
    get("/conversations/:conversation_id/members", ConversationController, :members)
    post("/conversations/:conversation_id/members", ConversationController, :add_member)

    get(
      "/conversations/:conversation_id/remote-join-requests",
      ConversationController,
      :pending_remote_join_requests
    )

    post(
      "/conversations/:conversation_id/remote-join-requests/approve",
      ConversationController,
      :approve_remote_join_request
    )

    post(
      "/conversations/:conversation_id/remote-join-requests/decline",
      ConversationController,
      :decline_remote_join_request
    )

    delete(
      "/conversations/:conversation_id/members/:user_id",
      ConversationController,
      :remove_member
    )

    # Messages
    get("/conversations/:conversation_id/messages", MessageController, :index)
    post("/conversations/:conversation_id/messages", MessageController, :create)
    put("/messages/:id", MessageController, :update)
    delete("/messages/:id", MessageController, :delete)

    # Chat media upload
    post("/conversations/:conversation_id/upload", ConversationController, :upload_media)

    # Message reactions
    post("/messages/:message_id/reactions", MessageController, :add_reaction)
    delete("/messages/:message_id/reactions/:emoji", MessageController, :remove_reaction)

    # Social/Timeline API
    get("/social/timeline", SocialController, :timeline)
    get("/social/timeline/public", SocialController, :public_timeline)

    # Posts
    get("/social/posts/:id", SocialController, :show_post)
    post("/social/posts", SocialController, :create_post)
    delete("/social/posts/:id", SocialController, :delete_post)

    # Post interactions
    post("/social/posts/:id/like", SocialController, :like_post)
    delete("/social/posts/:id/like", SocialController, :unlike_post)
    post("/social/posts/:id/repost", SocialController, :repost)
    delete("/social/posts/:id/repost", SocialController, :unrepost)

    # Comments
    get("/social/posts/:post_id/comments", SocialController, :list_comments)
    post("/social/posts/:post_id/comments", SocialController, :create_comment)
    delete("/social/comments/:id", SocialController, :delete_comment)
    post("/social/comments/:id/like", SocialController, :like_comment)
    delete("/social/comments/:id/like", SocialController, :unlike_comment)

    # Following
    get("/social/followers", SocialController, :list_followers)
    get("/social/following", SocialController, :list_following)

    # User profiles and actions
    get("/social/users/search", SocialController, :search_users)
    get("/social/users/:id", SocialController, :show_user)
    get("/social/users/:user_id/posts", SocialController, :user_posts)
    get("/social/users/:user_id/followers", SocialController, :user_followers)
    get("/social/users/:user_id/following", SocialController, :user_following)
    post("/social/users/:user_id/follow", SocialController, :follow_user)
    delete("/social/users/:user_id/follow", SocialController, :unfollow_user)
    post("/social/users/:user_id/block", SocialController, :block_user)
    delete("/social/users/:user_id/block", SocialController, :unblock_user)

    # Friend requests
    get("/social/friend-requests", SocialController, :list_friend_requests)
    post("/social/friend-requests/:id/accept", SocialController, :accept_friend_request)
    delete("/social/friend-requests/:id", SocialController, :reject_friend_request)

    # Communities
    get("/social/communities", SocialController, :list_communities)
    get("/social/communities/mine", SocialController, :my_communities)
    get("/social/communities/search", SocialController, :search_communities)
    get("/social/communities/:id", SocialController, :show_community)
    get("/social/communities/:community_id/posts", SocialController, :community_posts)
    post("/social/communities", SocialController, :create_community)
    post("/social/communities/:id/join", SocialController, :join_community)
    delete("/social/communities/:id/join", SocialController, :leave_community)

    # Media upload
    post("/social/upload", SocialController, :upload_media)

    # Data Export API
    get("/exports", ExportController, :index)
    post("/export", ExportController, :create)
    get("/export/:id", ExportController, :show)
    delete("/export/:id", ExportController, :delete)
  end

  # External PAT-authenticated API endpoints for integrations.
  scope "/api/ext/v1", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated])

    get("/capabilities", MetaController, :capabilities)
  end

  scope "/api/ext/v1", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_account_read_scope])

    get("/me", MetaController, :me)
  end

  scope "/api/ext/v1/search", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_search_read_scope])

    get("/", GlobalSearchController, :index)
    get("/actions", GlobalSearchController, :actions)
    post("/actions/execute", GlobalSearchController, :execute)
  end

  scope "/api/ext/v1/email", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_email_read_scope])

    get("/messages", ExtEmailController, :index)
    get("/messages/:id", ExtEmailController, :show)
  end

  scope "/api/ext/v1/email", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_email_write_scope])

    post("/messages", ExtEmailController, :create)
  end

  scope "/api/ext/v1/chat", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_chat_read_scope])

    get("/conversations", ExtChatController, :index)
    get("/conversations/:id", ExtChatController, :show)
    get("/conversations/:id/messages", ExtChatController, :messages)
  end

  scope "/api/ext/v1/chat", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_chat_write_scope])

    post("/conversations/:id/messages", ExtChatController, :create)
  end

  scope "/api/ext/v1/social", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_social_read_scope])

    get("/feed", ExtSocialController, :feed)
    get("/posts/:id", ExtSocialController, :show)
    get("/users/:user_id/posts", ExtSocialController, :user_posts)
  end

  scope "/api/ext/v1/social", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_social_write_scope])

    post("/posts", ExtSocialController, :create)
  end

  scope "/api/ext/v1/contacts", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_contacts_read_scope])

    get("/", ExtContactsController, :index)
    get("/:id", ExtContactsController, :show)
  end

  scope "/api/ext/v1/calendars", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_calendar_read_scope])

    get("/", CalendarController, :index)
    get("/:id/events", CalendarController, :events)
  end

  scope "/api/ext/v1/calendars", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_calendar_write_scope])

    post("/", CalendarController, :create)
    post("/:id/events", CalendarController, :create_event)
  end

  scope "/api/ext/v1/events", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_calendar_write_scope])

    put("/:id", CalendarController, :update_event)
    delete("/:id", CalendarController, :delete_event)
  end

  scope "/api/ext/v1/password-manager", ElektrineWeb.API do
    pipe_through([:api_vault_authenticated, :api_pat_vault_read_scope])

    scope "/", alias: false do
      get("/entries", ElektrinePasswordManagerWeb.API.VaultController, :index)
      get("/entries/:id", ElektrinePasswordManagerWeb.API.VaultController, :show)
    end
  end

  scope "/api/ext/v1/password-manager", ElektrineWeb.API do
    pipe_through([:api_vault_authenticated, :api_pat_vault_write_scope])

    scope "/", alias: false do
      post("/vault/setup", ElektrinePasswordManagerWeb.API.VaultController, :setup)
      delete("/vault", ElektrinePasswordManagerWeb.API.VaultController, :delete_vault)
      post("/entries", ElektrinePasswordManagerWeb.API.VaultController, :create)
      put("/entries/:id", ElektrinePasswordManagerWeb.API.VaultController, :update)
      delete("/entries/:id", ElektrinePasswordManagerWeb.API.VaultController, :delete)
    end
  end

  scope "/api/ext/v1/exports", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_export_scope])

    get("/", ExportController, :index)
    post("/", ExportController, :create)
    get("/:id", ExportController, :show)
    delete("/:id", ExportController, :delete)
    get("/:id/download", ExportController, :download_authenticated)
  end

  scope "/api/ext/v1/webhooks", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_webhook_scope])

    get("/", WebhookController, :index)
    post("/", WebhookController, :create)
    get("/:id", WebhookController, :show)
    delete("/:id", WebhookController, :delete)
    post("/:id/test", WebhookController, :test)
    post("/:id/rotate-secret", WebhookController, :rotate_secret)
    get("/:id/deliveries", WebhookController, :deliveries)
    post("/:id/deliveries/:delivery_id/replay", WebhookController, :replay)
  end

  # Backward-compatible unversioned external endpoints.
  scope "/api/ext/search", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_search_read_scope])

    get("/", GlobalSearchController, :index)
    get("/actions", GlobalSearchController, :actions)
    post("/actions/execute", GlobalSearchController, :execute)
  end

  scope "/api/ext/calendars", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_calendar_read_scope])

    get("/", CalendarController, :index)
    get("/:id/events", CalendarController, :events)
  end

  scope "/api/ext/calendars", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_calendar_write_scope])

    post("/", CalendarController, :create)
    post("/:id/events", CalendarController, :create_event)
  end

  scope "/api/ext/events", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_calendar_write_scope])

    put("/:id", CalendarController, :update_event)
    delete("/:id", CalendarController, :delete_event)
  end

  scope "/api/ext/password-manager", ElektrineWeb.API do
    pipe_through([:api_vault_authenticated, :api_pat_vault_read_scope])

    scope "/", alias: false do
      get("/entries", ElektrinePasswordManagerWeb.API.VaultController, :index)
      get("/entries/:id", ElektrinePasswordManagerWeb.API.VaultController, :show)
    end
  end

  scope "/api/ext/password-manager", ElektrineWeb.API do
    pipe_through([:api_vault_authenticated, :api_pat_vault_write_scope])

    scope "/", alias: false do
      post("/vault/setup", ElektrinePasswordManagerWeb.API.VaultController, :setup)
      delete("/vault", ElektrinePasswordManagerWeb.API.VaultController, :delete_vault)
      post("/entries", ElektrinePasswordManagerWeb.API.VaultController, :create)
      put("/entries/:id", ElektrinePasswordManagerWeb.API.VaultController, :update)
      delete("/entries/:id", ElektrinePasswordManagerWeb.API.VaultController, :delete)
    end
  end

  # Data Export Download (separate scope - token-based auth, no session needed)
  scope "/api", ElektrineWeb.API do
    pipe_through(:api)

    get("/export/:id/download", ExportController, :download)
  end

  # Mobile/Flutter app API endpoints - Development only
  if Application.compile_env(:elektrine, :dev_routes) do
    # Mobile/Flutter app API endpoints - Public (no auth required)
    scope "/api", ElektrineWeb.API do
      pipe_through(:api)

      # Registration (dev only)
      post("/users/register", UserController, :register)
    end

    # Mobile/Flutter app API endpoints - Authenticated (dev only)
    scope "/api", ElektrineWeb.API do
      pipe_through(:api_authenticated)

      # User endpoints (dev only)
      get("/users/:id", UserController, :show)
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview
  import Phoenix.LiveDashboard.Router

  # LiveDashboard for admins in production - require elektrine.com domain
  scope "/pripyat" do
    pipe_through([:browser, :require_admin_access, ElektrineWeb.Plugs.RequireElektrineDomain])

    live_dashboard("/dashboard",
      metrics: ElektrineWeb.Telemetry,
      additional_pages: [
        oban: Oban.LiveDashboard
      ]
    )
  end

  # Development-only routes
  if Application.compile_env(:elektrine, :dev_routes) do
    scope "/dev" do
      pipe_through(:browser)

      forward("/mailbox", Plug.Swoosh.MailboxPreview)

      # Flash testing routes (controller redirect path)
      get("/flash-test/controller/:kind", ElektrineWeb.PageController, :flash_test_controller)

      # Test routes for error pages
      get("/test-403", ElektrineWeb.PageController, :test_403)
      get("/test-404", ElektrineWeb.PageController, :test_404)
      get("/test-413", ElektrineWeb.PageController, :test_413)
      get("/test-500", ElektrineWeb.PageController, :test_500)
    end
  end

  # Main LiveView routes - MUST be at end of router due to /:handle catch-all
  # All pages in single live_session for seamless navigation
  scope "/",
        ElektrineWeb,
        host:
          Application.compile_env(:elektrine, :profile_host_scope, @default_profile_host_scope) do
    pipe_through(:profile)

    get("/", ProfileController, :show)
    get("/:handle", ProfileController, :show)
  end

  scope "/", ElektrineWeb do
    pipe_through(:browser)

    get("/subdomain/:handle", ProfileController, :show)
  end

  scope "/", ElektrineWeb do
    pipe_through(:browser)

    live_session :main,
      on_mount: [
        {ElektrineWeb.Live.Hooks.PlatformModuleHook, :default},
        {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user},
        {ElektrineWeb.Live.Hooks.NotificationCountHook, :default},
        {ElektrineWeb.Live.Hooks.TimezoneHook, :default},
        {ElektrineWeb.Live.Hooks.PresenceHook, :default}
      ] do
      # Home page
      live("/", PageLive.Home, :index)

      # Static pages
      live("/about", PageLive.About, :index)
      live("/terms", PageLive.Terms, :index)
      live("/privacy", PageLive.Privacy, :index)
      live("/faq", PageLive.FAQ, :index)
      live("/contact", PageLive.Contact, :index)
      live("/vpn/policy", PageLive.VPNPolicy, :index)

      if Application.compile_env(:elektrine, :dev_routes) do
        # Flash testing page (LiveView path)
        live("/dev/flash-test", PageLive.DevFlashTest, :index)
      end

      # Unsubscribe (GET only - POST stays as controller)
      live("/unsubscribe/:token", UnsubscribeLive.Show, :show)

      # Overview
      live("/overview", OverviewLive.Index, :index)
      live("/reputation", ReputationLive.Show, :index)
      live("/reputation/:handle", ReputationLive.Show, :show)

      # Communities (formerly Discussions)
      live("/communities", DiscussionsLive.Index, :index)
      live("/communities/:name", DiscussionsLive.Community, :show)
      live("/communities/:name/settings", DiscussionsLive.Settings, :index)
      live("/communities/:name/post/:post_id", DiscussionsLive.Post, :show)

      # Legacy redirects (backwards compatibility)
      live("/discussions", DiscussionsLive.Index, :index)
      live("/discussions/:name", DiscussionsLive.Community, :show)
      live("/discussions/:name/settings", DiscussionsLive.Settings, :index)
      live("/discussions/:name/post/:post_id", DiscussionsLive.Post, :show)

      # Timeline
      live("/timeline", TimelineLive.Index, :index)
      live("/timeline/post/:id", TimelineLive.Post, :show)
      live("/hashtag/:hashtag", HashtagLive.Show, :show)

      # Lists
      live("/lists", ListLive.Index, :index)
      live("/lists/:id", ListLive.Show, :show)

      # Gallery
      live("/gallery", GalleryLive.Index, :index)

      # Remote user profiles
      live("/remote/:handle", RemoteUserLive.Show, :show)

      # Remote post detail
      live("/remote/post/:post_id", RemotePostLive.Show, :show)

      # Subscription pages
      live("/subscribe/:product", SubscribeLive, :index)

      # === Authenticated routes (auth checked in mount via current_user assign) ===

      # Account settings
      live("/account", UserSettingsLive)
      live("/account/password", SettingsLive.EditPassword, :edit)
      live("/account/two_factor/setup", SettingsLive.TwoFactorSetup, :setup)
      live("/account/two_factor", SettingsLive.TwoFactorManage, :manage)
      live("/account/passkeys", SettingsLive.PasskeyManage, :manage)
      live("/account/delete", SettingsLive.DeleteAccount, :delete)

      # Profile editing
      live("/account/profile/edit", ProfileLive.Edit, :edit)
      live("/account/profile/domains", ProfileLive.Domains, :index)
      live("/account/profile/analytics", ProfileLive.Analytics, :analytics)
      live("/account/storage", StorageLive)

      # Chat/Messaging
      live("/chat", ChatLive.Index, :index)
      live("/chat/:conversation_id", ChatLive.Index, :conversation)
      live("/chat/join/:conversation_id", ChatLive.Index, :join)
      live("/friends", FriendsLive, :index)

      # Notifications
      live("/notifications", NotificationsLive, :index)

      # Settings
      live("/account/app-passwords", SettingsLive.AppPasswords)

      scope "/", alias: false do
        live("/account/password-manager", ElektrinePasswordManagerWeb.VaultLive, :index)
      end

      live("/settings/rss", SettingsLive.RSS, :index)

      # Email
      live("/email", EmailLive.Index, :index)
      live("/email/compose", EmailLive.Compose, :new)
      live("/email/view/:id", EmailLive.Show, :show)
      live("/email/:id/raw", EmailLive.Raw)
      live("/email/search", EmailLive.Search, :search)
      live("/email/settings", EmailLive.Settings, :index)

      # VPN
      live("/vpn", VPNLive.Index, :index)

      # Contacts
      live("/contacts", ContactsLive.Index, :index)
      live("/contacts/:id", ContactsLive.Index, :show)

      # Calendar
      live("/calendar", EmailLive.Index, :calendar)

      # Global Search
      live("/search", SearchLive, :index)
    end
  end

  # ===========================================================================
  # Profile Routes
  # ===========================================================================
  # These routes support both LiveView and static profile pages.
  # Static pages (used on subdomains) need JSON API endpoints for interactions.

  # Profile JSON API - Returns JSON for AJAX calls from static profile pages
  # Used by assets/js/profile_static.js for follow, friend, and modal functionality
  scope "/", ElektrineWeb do
    pipe_through(:browser_api)

    # Followers/Following lists (for modals)
    get("/profiles/:handle/followers", ProfileController, :followers)
    get("/profiles/:handle/following", ProfileController, :following)

    # Follow/Unfollow actions
    post("/profiles/:handle/follow", ProfileController, :follow)
    delete("/profiles/:handle/follow", ProfileController, :unfollow)

    # Friend request actions
    post("/profiles/:handle/friend-request", ProfileController, :send_friend_request)
    post("/profiles/:handle/friend-request/accept", ProfileController, :accept_friend_request)
    delete("/profiles/:handle/friend-request", ProfileController, :cancel_friend_request)
    delete("/profiles/:handle/friend", ProfileController, :unfriend)
  end

  # Profile page - Renders static HTML profile
  # Used for subdomain access (username.<profile-domain>) and SEO
  # IMPORTANT: This catch-all route MUST be last in the router
  scope "/", ElektrineWeb do
    pipe_through(:browser)

    get("/:handle", ProfileController, :show)
  end
end
