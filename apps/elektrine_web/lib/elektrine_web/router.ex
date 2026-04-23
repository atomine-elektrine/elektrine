defmodule ElektrineWeb.Router do
  use ElektrineWeb, :router

  require ElektrineWeb.Routes.Chat
  require ElektrineWeb.Routes.Email
  require ElektrineWeb.Routes.DNS
  require ElektrineWeb.Routes.Social
  require ElektrineWeb.Routes.Vault
  require ElektrineWeb.Routes.VPN
  import ElektrineWeb.UserAuth

  @profile_host_scope (case System.get_env("PRIMARY_DOMAIN") do
                         domain when is_binary(domain) and domain != "" -> "*.#{domain}"
                         _ -> "*.example.com"
                       end)

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

  pipeline :well_known_text do
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.TorAware)
    plug(ElektrineWeb.Plugs.RequestTelemetry, scope: :api)
  end

  pipeline :api_rate_limited do
    plug(ElektrineWeb.Plugs.APIRateLimit)
  end

  pipeline :caddy_internal_api do
    plug(ElektrineWeb.Plugs.InternalAPIAuth,
      env_names: ["CADDY_EDGE_API_KEY", "PHOENIX_API_KEY"],
      param_names: ["token"]
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

  pipeline :api_pat_dns_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["read:dns", "write:dns"], any: true)
  end

  pipeline :api_pat_dns_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:dns"])
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

    plug(ElektrineWeb.Plugs.OptionalDelegate,
      resolver: {ElektrineWeb.Platform.ModuleDelegates, :optional_delegate},
      opts: [],
      module_name: :jmap_auth
    )

    plug(ElektrineWeb.Plugs.APIRateLimit)
  end

  pipeline :jmap_discovery do
    # JMAP discovery (authenticated)
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)

    plug(ElektrineWeb.Plugs.OptionalDelegate,
      resolver: {ElektrineWeb.Platform.ModuleDelegates, :optional_delegate},
      opts: [],
      module_name: :jmap_auth
    )
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

  # Health check endpoint (no auth required)
  scope "/", ElektrineWeb do
    pipe_through(:api)

    get("/health", HealthController, :check)
  end

  # Stripe webhook (no auth, signature verified in controller)
  scope "/webhook", ElektrineWeb do
    pipe_through(:api)

    post("/stripe", StripeWebhookController, :webhook)
  end

  # Internal Caddy on-demand TLS allowlist endpoint.
  # This stays on the private/origin app hostname and should be called only by the Caddy edge.
  scope "/_edge/tls/v1", ElektrineWeb do
    pipe_through([:api, :caddy_internal_api])

    get("/allow", CaddyTLSController, :allow)
  end

  # Media proxy for federation privacy (no auth required)
  scope "/media_proxy", alias: false do
    pipe_through(:api)

    ElektrineWeb.Routes.Social.media_proxy_routes()
  end

  scope "/api", ElektrineWeb do
    pipe_through([ElektrineWeb.Plugs.RequirePlatformModule])

    ElektrineWeb.Routes.Chat.private_attachment_routes()
  end

  # Lightweight signed messaging federation endpoints (instance-to-instance)
  scope "/_arblarg", ElektrineWeb do
    pipe_through([:api, :messaging_federation])

    ElektrineWeb.Routes.Chat.messaging_federation_routes()
  end

  scope "/_arblarg", ElektrineWeb do
    pipe_through([:messaging_federation])

    ElektrineWeb.Routes.Chat.messaging_federation_session_routes()
  end

  # Public messaging federation server directory for cross-instance discovery
  scope "/_arblarg", ElektrineWeb do
    pipe_through(:api)

    ElektrineWeb.Routes.Chat.public_directory_routes()
  end

  # Public Arblarg schema registry
  scope "/_arblarg", ElektrineWeb do
    pipe_through(:api)

    ElektrineWeb.Routes.Chat.public_schema_routes()
  end

  # Public well-known discovery for Arblarg messaging federation identity/capabilities
  scope "/.well-known", ElektrineWeb do
    pipe_through(:api)

    ElektrineWeb.Routes.Chat.well_known_routes()
  end

  ElektrineWeb.Routes.Email.autoconfig_routes()

  # CalDAV/CardDAV discovery
  scope "/.well-known", ElektrineWeb do
    pipe_through(:dav_discovery)

    get("/caldav", DAVController, :caldav_discovery)
    get("/carddav", DAVController, :carddav_discovery)
  end

  scope "/drive-dav", ElektrineWeb.DAV do
    pipe_through(:dav)

    match(:propfind, "/:username", DriveController, :propfind_home)
    match(:propfind, "/:username/*path", DriveController, :propfind_resource)
    match(:mkcol, "/:username/*path", DriveController, :mkcol)
    match(:move, "/:username/*path", DriveController, :move_resource)
    get("/:username/*path", DriveController, :get_file)
    put("/:username/*path", DriveController, :put_file)
    delete("/:username/*path", DriveController, :delete_resource)
  end

  ElektrineWeb.Routes.Email.wkd_routes()

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

  ElektrineWeb.Routes.Email.dav_and_jmap_routes()

  # Principal resources for DAV
  scope "/principals/users", ElektrineWeb.DAV do
    pipe_through(:dav)

    match(:propfind, "/:username", PrincipalController, :propfind)
  end

  scope "/.well-known", ElektrineWeb do
    pipe_through(:well_known_text)

    get("/atproto-did", BlueskyIdentityController, :well_known_did)
  end

  ElektrineWeb.Routes.Social.discovery_routes()

  # Routes that don't require authentication (MOVED BEFORE ActivityPub to prioritize browser requests)
  scope "/", ElektrineWeb do
    pipe_through(:browser)

    # SEO
    get("/sitemap.xml", SitemapController, :index)
    get("/robots.txt", SitemapController, :robots)

    scope "/", alias: false do
      ElektrineWeb.Routes.Social.public_browser_routes()
      ElektrineWeb.Routes.Email.public_browser_routes()
    end

    # Temporary email routes disabled
    # Guest temporary mail system has been disabled for security

    # Link click tracking and redirect
    get("/l/:id", LinkController, :click)

    # Public file shares
    get("/drive/share/:token", DriveShareController, :show)
    post("/drive/share/:token", DriveShareController, :authorize)
    get("/notes/share/:token", NoteShareController, :show)
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

  ElektrineWeb.Routes.Social.activitypub_routes()

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
    get("/account/developer/oidc/clients", OIDCClientController, :index)
    get("/account/developer/oidc/clients/new", OIDCClientController, :new)
    get("/account/developer/oidc/clients/:id/edit", OIDCClientController, :edit)
    post("/account/developer/oidc/clients", OIDCClientController, :create)
    put("/account/developer/oidc/clients/:id", OIDCClientController, :update)

    post(
      "/account/developer/oidc/clients/:id/rotate-secret",
      OIDCClientController,
      :rotate_secret
    )

    delete("/account/developer/oidc/clients/:id", OIDCClientController, :delete)
    get("/account/developer/oidc/grants", OIDCGrantController, :index)
    delete("/account/developer/oidc/grants/:id", OIDCGrantController, :delete)

    # Announcement dismissal
    post("/announcements/:id/dismiss", UserSettingsController, :dismiss_announcement)

    # User status update
    post("/account/status", UserSettingsController, :set_status)

    scope "/", alias: false do
      ElektrineWeb.Routes.Email.authenticated_browser_routes()
    end

    # Personal file downloads
    get("/account/drive/:id/download", DriveController, :download)
    get("/account/drive/:id/preview", DriveController, :preview)

    # NOTE: All LiveView routes moved to single public_content live_session at end of router
    # for seamless navigation. Auth is enforced by pipe_through :require_authenticated_user
  end

  # Impersonation exit route (must be accessible while acting as a non-admin user)
  scope "/pripyat", ElektrineWeb do
    pipe_through([:browser, :require_authenticated_user])

    post("/stop-impersonation", Admin.UsersController, :stop_impersonation)
  end

  # Admin security routes (elevation + per-action passkey re-sign)
  scope "/pripyat/security", ElektrineWeb do
    pipe_through([:browser, :require_authenticated_user, :require_admin_user])

    get("/elevate", Admin.SecurityController, :elevate)
    post("/elevate/start", Admin.SecurityController, :start_elevation)
    post("/elevate/finish", Admin.SecurityController, :finish_elevation)
    post("/action/start", Admin.SecurityController, :start_action)
    post("/action/finish", Admin.SecurityController, :finish_action)
  end

  # Admin routes - require admin privileges
  scope "/pripyat", ElektrineWeb do
    pipe_through([:browser, :require_admin_access])

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

    scope "/", alias: false do
      ElektrineWeb.Routes.Email.admin_routes()
      ElektrineWeb.Routes.Chat.admin_routes()
    end

    # Monitoring (Admin.MonitoringController)
    get("/active-users", Admin.MonitoringController, :active_users)
    get("/imap-users", Admin.MonitoringController, :imap_users)
    get("/pop3-users", Admin.MonitoringController, :pop3_users)
    get("/2fa-status", Admin.MonitoringController, :two_factor_status)
    get("/system-health", Admin.MonitoringController, :system_health)

    # Deletion requests (Admin.DeletionRequestsController)
    get("/deletion-requests", Admin.DeletionRequestsController, :index)
    get("/deletion-requests/:id", Admin.DeletionRequestsController, :show)
    post("/deletion-requests/bulk-approve", Admin.DeletionRequestsController, :bulk_approve)
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

    ElektrineWeb.Routes.VPN.admin_routes()
  end

  # Admin LiveView routes - wrapped in live_session for authentication
  scope "/pripyat", ElektrineWeb do
    pipe_through([:browser, :require_admin_access])

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
    post("/locale/switch", LocaleController, :switch)
    get("/oauth/authorize", OIDCController, :authorize)
    post("/oauth/authorize", OIDCController, :approve)
  end

  scope "/.well-known", ElektrineWeb do
    pipe_through(:api)

    get("/openid-configuration", OIDCController, :configuration)
  end

  # ===========================================================================
  # Mastodon-compatible API routes
  # ===========================================================================
  # These routes provide compatibility with Mastodon third-party clients
  # like Tusky, Ivory, Ice Cubes, Elk, etc.

  ElektrineWeb.Routes.Social.mastodon_routes()

  scope "/oauth", ElektrineWeb do
    pipe_through(:api)

    get("/jwks", OIDCController, :jwks)
    get("/userinfo", OIDCController, :userinfo)
    post("/userinfo", OIDCController, :userinfo)
  end

  scope "/oauth", ElektrineWeb do
    pipe_through([:browser_api, :require_authenticated_user])

    post("/register", OIDCController, :dynamic_register)
  end

  # Other scopes may use custom stacks.
  scope "/api", alias: false do
    pipe_through(:api)

    ElektrineWeb.Routes.Email.internal_api_routes()
    ElektrineWeb.Routes.VPN.internal_api_routes()
  end

  # Mobile app authentication - Always available for VPN access
  scope "/api", ElektrineWeb.API do
    pipe_through(:api)

    # Authentication endpoints (no auth required)
    post("/auth/login", AuthController, :login)
  end

  # Mobile app authenticated endpoints - Always available for VPN
  scope "/api", alias: false do
    pipe_through(:api_authenticated)

    # Auth endpoints (require token)
    post("/auth/logout", ElektrineWeb.API.AuthController, :logout)
    get("/auth/me", ElektrineWeb.API.AuthController, :me)

    # Settings endpoints
    get("/settings", ElektrineWeb.API.SettingsController, :index)
    put("/settings/profile", ElektrineWeb.API.SettingsController, :update_profile)
    put("/settings/notifications", ElektrineWeb.API.SettingsController, :update_notifications)
    put("/settings/password", ElektrineWeb.API.SettingsController, :update_password)
    post("/settings/bluesky/enable", ElektrineWeb.API.SettingsController, :enable_bluesky_managed)

    # VPN endpoints
    ElektrineWeb.Routes.VPN.authenticated_api_routes()

    ElektrineWeb.Routes.Email.authenticated_api_routes()

    # Device registration for push notifications
    get("/devices", ElektrineWeb.API.DeviceController, :index)
    post("/devices", ElektrineWeb.API.DeviceController, :create)
    delete("/devices/:token", ElektrineWeb.API.DeviceController, :delete)

    # Notifications
    get("/notifications", ElektrineWeb.API.NotificationController, :index)
    post("/notifications/:id/read", ElektrineWeb.API.NotificationController, :mark_read)
    post("/notifications/read-all", ElektrineWeb.API.NotificationController, :mark_all_read)
    delete("/notifications/:id", ElektrineWeb.API.NotificationController, :dismiss)

    ElektrineWeb.Routes.Chat.authenticated_api_routes()
    ElektrineWeb.Routes.Social.authenticated_api_routes()

    # Data Export API
    get("/exports", ElektrineWeb.API.ExportController, :index)
    post("/export", ElektrineWeb.API.ExportController, :create)
    get("/export/:id", ElektrineWeb.API.ExportController, :show)
    delete("/export/:id", ElektrineWeb.API.ExportController, :delete)
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

  scope "/api/ext/v1/email", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_email_read_scope])

    ElektrineWeb.Routes.Email.ext_api_read_routes()
  end

  scope "/api/ext/v1/email", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_email_write_scope])

    ElektrineWeb.Routes.Email.ext_api_write_routes()
  end

  scope "/api/ext/v1/chat", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_chat_read_scope])

    ElektrineWeb.Routes.Chat.ext_api_read_routes()
  end

  scope "/api/ext/v1/chat", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_chat_write_scope])

    ElektrineWeb.Routes.Chat.ext_api_write_routes()
  end

  scope "/api/ext/v1/social", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_social_read_scope])

    ElektrineWeb.Routes.Social.ext_api_read_routes()
  end

  scope "/api/ext/v1/social", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_social_write_scope])

    ElektrineWeb.Routes.Social.ext_api_write_routes()
  end

  scope "/api/ext/v1/contacts", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_contacts_read_scope])

    ElektrineWeb.Routes.Email.ext_contacts_routes()
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

    ElektrineWeb.Routes.Vault.api_read_routes()
  end

  scope "/api/ext/v1/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_read_scope])

    ElektrineWeb.Routes.DNS.api_read_routes()
  end

  scope "/api/ext/v1/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_write_scope])

    ElektrineWeb.Routes.DNS.api_write_routes()
  end

  scope "/api/ext/v1/password-manager", ElektrineWeb.API do
    pipe_through([:api_vault_authenticated, :api_pat_vault_write_scope])

    ElektrineWeb.Routes.Vault.api_write_routes()
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

    ElektrineWeb.Routes.Vault.api_read_routes()
  end

  scope "/api/ext/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_read_scope])

    ElektrineWeb.Routes.DNS.api_read_routes()
  end

  scope "/api/ext/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_write_scope])

    ElektrineWeb.Routes.DNS.api_write_routes()
  end

  scope "/api/ext/password-manager", ElektrineWeb.API do
    pipe_through([:api_vault_authenticated, :api_pat_vault_write_scope])

    ElektrineWeb.Routes.Vault.api_write_routes()
  end

  # Data export download for the logged-in browser UI.
  # Requires the browser session plus the per-export download token.
  scope "/api", ElektrineWeb.API do
    pipe_through(:browser_api)

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

  # LiveDashboard for admins in production
  scope "/pripyat" do
    pipe_through([:browser, :require_admin_access])

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
        host: @profile_host_scope do
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

      ElektrineWeb.Routes.VPN.public_live_routes()

      if Application.compile_env(:elektrine, :dev_routes) do
        # Flash testing page (LiveView path)
        live("/dev/flash-test", PageLive.DevFlashTest, :index)
      end

      scope "/", alias: false do
        ElektrineWeb.Routes.Email.main_live_routes()
        ElektrineWeb.Routes.Social.main_live_routes()
        ElektrineWeb.Routes.Chat.main_live_routes()
        ElektrineWeb.Routes.VPN.main_live_routes()
        ElektrineWeb.Routes.DNS.main_live_routes()
      end

      # Overview
      live("/overview", OverviewLive.Index, :index)
      live("/reputation", ReputationLive.Show, :index)
      live("/reputation/:handle", ReputationLive.Show, :show)

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
      live("/account/profile/domains/analytics", ProfileLive.DomainAnalytics, :analytics)
      live("/account/profile/analytics", ProfileLive.Analytics, :analytics)
      live("/account/storage", StorageLive)
      live("/account/drive", DriveLive)
      live("/account/notes", NotesLive)

      live("/friends", FriendsLive, :index)

      # Notifications
      live("/notifications", NotificationsLive, :index)

      # Settings
      live("/account/app-passwords", SettingsLive.AppPasswords)

      get(
        "/account/password-manager/extension/:browser/download",
        PasswordManagerExtensionController,
        :download
      )

      ElektrineWeb.Routes.Vault.live_routes()

      live("/settings/rss", SettingsLive.RSS, :index)

      live("/dns/analytics", ProfileLive.DomainAnalytics, :analytics)

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
