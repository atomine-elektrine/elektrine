defmodule ElektrineWeb.Router do
  use ElektrineWeb, :router

  require ElektrineWeb.Routes.Chat
  require ElektrineWeb.Routes.Email
  require ElektrineWeb.Routes.DNS
  require ElektrineWeb.Routes.Social
  require ElektrineWeb.Routes.Nerve
  require ElektrineWeb.Routes.VPN
  require ElektrineWeb.Routes.Uptime
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
    plug(ElektrineWeb.Plugs.SitePageTracking)
    plug(ElektrineWeb.Plugs.StaticSitePlug)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ElektrineWeb.Layouts, :root})
    plug(:protect_from_forgery, with: :clear_session)
    plug(ElektrineWeb.Plugs.CSRFErrorHandler)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_user)
    plug(ElektrineWeb.Plugs.PostHogContext)
    plug(ElektrineWeb.Plugs.RequireModuleAccess)
    plug(ElektrineWeb.Plugs.Locale)
    plug(ElektrineWeb.Plugs.TimezonePlug)
    plug(ElektrineWeb.Plugs.NotificationCount)
  end

  pipeline :profile do
    plug(:accepts, ["html"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.TorAware)
    plug(:fetch_session)
    plug(ElektrineWeb.Plugs.SitePageTracking)
    plug(ElektrineWeb.Plugs.StaticSitePlug)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ElektrineWeb.Layouts, :root})
    plug(:protect_from_forgery, with: :clear_session)
    plug(ElektrineWeb.Plugs.CSRFErrorHandler)
    plug(:put_secure_browser_headers)
    plug(ElektrineWeb.Plugs.ProfileCSP)
    plug(:fetch_current_user)
    plug(ElektrineWeb.Plugs.PostHogContext)
    plug(ElektrineWeb.Plugs.RequireModuleAccess)
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
      env_names: ["CADDY_EDGE_API_KEY"]
    )
  end

  pipeline :caddy_tls_ask_api do
    plug(ElektrineWeb.Plugs.InternalAPIAuth,
      env_names: ["CADDY_EDGE_API_KEY"],
      source_cidrs_env_names: [
        "CADDY_ASK_TRUSTED_CIDRS",
        "PROXY_PROTOCOL_TRUSTED_CIDRS",
        "TRUSTED_PROXY_CIDRS"
      ]
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
    plug(ElektrineWeb.Plugs.PostHogContext)
    plug(ElektrineWeb.Plugs.RequireModuleAccess)
  end

  pipeline :api_authenticated do
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.APIRateLimit, key_prefix: "preauth", ip_only: true)
    plug(ElektrineWeb.Plugs.APIAuth)
    plug(ElektrineWeb.Plugs.RequireModuleAccess)
    plug(ElektrineWeb.Plugs.APIRateLimit)
    plug(ElektrineWeb.Plugs.RequestTelemetry, scope: :api)
  end

  pipeline :api_pat_authenticated do
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.APIRateLimit, key_prefix: "preauth", ip_only: true)
    plug(ElektrineWeb.Plugs.PATAuth, allow_api_token: true)
    plug(ElektrineWeb.Plugs.RequireModuleAccess)
    plug(ElektrineWeb.Plugs.APIRateLimit)
    plug(ElektrineWeb.Plugs.RequestTelemetry, scope: :api)
  end

  pipeline :api_nerve_authenticated do
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.APIRateLimit, key_prefix: "preauth", ip_only: true)
    plug(ElektrineWeb.Plugs.PATAuth)
    plug(ElektrineWeb.Plugs.RequireModuleAccess)
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

  pipeline :api_pat_proofs_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["read:proofs", "write:proofs"], any: true)
  end

  pipeline :api_pat_proofs_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:proofs"])
  end

  pipeline :api_pat_static_site_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["read:static_site", "write:static_site"], any: true)
  end

  pipeline :api_pat_static_site_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:static_site"])
  end

  pipeline :api_pat_report_create_scope do
    plug(ElektrineWeb.Plugs.PATAuth,
      scopes: ["write:social", "write:moderation"],
      any: true,
      allow_api_token: true
    )
  end

  pipeline :api_pat_moderation_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth,
      scopes: ["read:moderation", "write:moderation"],
      any: true,
      allow_api_token: true
    )
  end

  pipeline :api_pat_moderation_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth,
      scopes: ["write:moderation"],
      allow_api_token: true
    )
  end

  pipeline :api_pat_dns_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["read:dns", "write:dns"], any: true)
  end

  pipeline :api_pat_dns_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:dns"])
  end

  pipeline :api_pat_nerve_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth,
      scopes: ["read:nerve", "write:nerve"],
      any: true
    )
  end

  pipeline :api_pat_nerve_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:nerve"])
  end

  pipeline :api_pat_kairo_read_scope do
    plug(ElektrineWeb.Plugs.PATAuth,
      scopes: ["read:kairo", "write:kairo"],
      any: true
    )
  end

  pipeline :api_pat_kairo_write_scope do
    plug(ElektrineWeb.Plugs.PATAuth, scopes: ["write:kairo"])
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
    plug(ElektrineWeb.Plugs.APIRateLimit, key_prefix: "activitypub", ip_only: true)
    # HTTP Signature validation (assigns :valid_signature and :signature_actor)
    plug(ElektrineWeb.Plugs.HTTPSignaturePlug)
    # Enforce signatures when authorized fetch mode is enabled
    plug(ElektrineWeb.Plugs.EnsureHTTPSignaturePlug)
  end

  pipeline :messaging_federation do
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.APIRateLimit, key_prefix: "federation_preauth", ip_only: true)
    plug(ElektrineWeb.Plugs.MessagingFederationAuth)
    plug(ElektrineWeb.Plugs.APIRateLimit)
  end

  pipeline :dav do
    # CalDAV/CardDAV pipeline
    plug(:accepts, ["xml", "text", "json"])
    plug(ElektrineWeb.Plugs.WebDAVMethodOverride)
    plug(ElektrineWeb.Plugs.DAVRateLimit, key_prefix: "preauth", ip_only: true)
    plug(ElektrineWeb.Plugs.DAVAuth)
    plug(ElektrineWeb.Plugs.RequireModuleAccess)
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
    plug(ElektrineWeb.Plugs.APIRateLimit)

    plug(ElektrineWeb.Plugs.OptionalDelegate,
      resolver: {ElektrineWeb.Platform.ModuleDelegates, :optional_delegate},
      opts: [],
      module_name: :jmap_auth
    )

    plug(ElektrineWeb.Plugs.RequireModuleAccess)
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

    plug(ElektrineWeb.Plugs.RequireModuleAccess)
  end

  pipeline :autoconfig do
    # Email client autodiscovery (no auth)
    plug(:accepts, ["xml", "html", "json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(:put_secure_browser_headers)
  end

  pipeline :unsubscribe_post do
    plug(:accepts, ["html", "text", "json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.TorAware)
    plug(:put_secure_browser_headers)
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
    pipe_through([:api, :caddy_tls_ask_api])

    get("/allow", CaddyTLSController, :allow)
  end

  # Internal DNS-01 automation endpoint used by acme.sh for wildcard certs.
  scope "/_edge/acme/dns/v1", ElektrineWeb do
    pipe_through([:api, :caddy_internal_api])

    post("/txt", InternalACMEDNSController, :add_txt)
    delete("/txt", InternalACMEDNSController, :remove_txt)
  end

  scope "/_edge/dns/v1", ElektrineWeb do
    pipe_through([:api, :caddy_internal_api])

    get("/health", InternalDNSController, :health)
  end

  scope "/_edge/proxy/v1", ElektrineWeb do
    pipe_through([:api, :caddy_internal_api])

    get("/origin", InternalEdgeProxyController, :origin)
  end

  # Media proxy for federation privacy (no auth required)
  scope "/media_proxy", alias: false do
    pipe_through([:api, :api_rate_limited])

    ElektrineWeb.Routes.Social.media_proxy_routes()
  end

  scope "/api", ElektrineWeb do
    pipe_through([:browser_api, :require_authenticated_user])

    ElektrineWeb.Routes.Chat.private_attachment_routes()
    post("/atomine/account/pow/receipts", API.AtomineAttestationController, :pow_receipt)
    post("/atomine/passkey-receipts", API.AtomineAttestationController, :passkey_receipt)
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

  scope "/", alias: false do
    pipe_through(:unsubscribe_post)

    post("/unsubscribe/:token", ElektrineEmailWeb.UnsubscribeController, :one_click)
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

  scope "/.well-known", ElektrineWeb do
    pipe_through(:api)

    get("/own-root", OwnRootController, :show)
    get("/did.json", OwnRootController, :did)
    get("/elektrine", OwnRootController, :show)
    get("/atomine", OwnRootController, :atomine)
  end

  ElektrineWeb.Routes.Social.discovery_routes()

  # Routes that don't require authentication (MOVED BEFORE ActivityPub to prioritize browser requests)
  scope "/", ElektrineWeb do
    pipe_through(:browser)

    # SEO
    get("/sitemap.xml", SitemapController, :index)
    get("/robots.txt", SitemapController, :robots)
    get("/canary", PageController, :canary)
    get("/canary/current.md", PageController, :canary_current)
    get("/canary/current.md.asc", PageController, :canary_signature)
    get("/canary-key.asc", PageController, :canary_public_key)

    scope "/", alias: false do
      ElektrineWeb.Routes.Social.public_browser_routes()
      ElektrineWeb.Routes.Email.public_browser_routes()
    end

    # Link click tracking and redirect
    get("/l/:id", LinkController, :click)

    # Public file shares
    get("/drive/share/:token", DriveShareController, :show)
    post("/drive/share/:token", DriveShareController, :authorize)
  end

  # Routes that are specifically for unauthenticated users
  scope "/", ElektrineWeb do
    pipe_through([
      :browser,
      :redirect_if_user_is_authenticated
    ])

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

    get("/account/connections/:provider/start", ConnectedAccountController, :start)
    get("/account/connections/:provider/callback", ConnectedAccountController, :callback)

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
    pipe_through([
      :browser,
      :require_vpn_when_netbird_enabled,
      :require_admin_host,
      :require_authenticated_user
    ])

    post("/stop-impersonation", Admin.UsersController, :stop_impersonation)
  end

  # Admin security routes (elevation + per-action passkey re-sign)
  scope "/pripyat/security", ElektrineWeb do
    pipe_through([
      :browser,
      :require_vpn_when_netbird_enabled,
      :require_admin_host,
      :require_authenticated_user,
      :require_admin_user
    ])

    get("/elevate", Admin.SecurityController, :elevate)
    post("/elevate/start", Admin.SecurityController, :start_elevation)
    post("/elevate/finish", Admin.SecurityController, :finish_elevation)
    post("/action/start", Admin.SecurityController, :start_action)
    post("/action/finish", Admin.SecurityController, :finish_action)
  end

  # Admin routes - require admin privileges
  scope "/pripyat", ElektrineWeb do
    pipe_through([
      :browser,
      :require_vpn_when_netbird_enabled,
      :require_admin_host,
      :require_admin_access
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
    get("/operations", Admin.MonitoringController, :operations)
    get("/active-users", Admin.MonitoringController, :active_users)
    get("/imap-users", Admin.MonitoringController, :imap_users)
    get("/pop3-users", Admin.MonitoringController, :pop3_users)
    get("/2fa-status", Admin.MonitoringController, :two_factor_status)
    get("/system-health", Admin.MonitoringController, :system_health)
    get("/job-queue-stats", Admin.MonitoringController, :job_queue_stats)
    get("/media-proxy-cache", Admin.MonitoringController, :media_proxy_cache)
    post("/media-proxy-cache/purge", Admin.MonitoringController, :purge_media_proxy_cache)
    post("/media-proxy-cache/unban", Admin.MonitoringController, :unban_media_proxy_cache)

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

    post(
      "/invite-codes/module-access",
      Admin.InviteCodesController,
      :update_module_access
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
    pipe_through([
      :browser,
      :require_vpn_when_netbird_enabled,
      :require_admin_host,
      :require_admin_access
    ])

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

  scope "/oauth", ElektrineWeb do
    pipe_through([:api, :api_rate_limited])

    get("/jwks", OIDCController, :jwks)
    post("/token", OIDCController, :token)
    get("/userinfo", OIDCController, :userinfo)
    post("/userinfo", OIDCController, :userinfo)
  end

  scope "/oauth", ElektrineWeb do
    pipe_through([:browser_api, :require_authenticated_user])

    post("/register", OIDCController, :dynamic_register)
  end

  # Other scopes may use custom stacks.
  scope "/api", alias: false do
    pipe_through([:api, :api_rate_limited])

    ElektrineWeb.Routes.Email.internal_api_routes()
    ElektrineWeb.Routes.VPN.internal_api_routes()
  end

  # Mobile app authentication - Always available for VPN access
  scope "/api", ElektrineWeb.API do
    pipe_through([:api, :api_rate_limited])

    # Authentication endpoints (no auth required)
    post("/auth/login", AuthController, :login)
    post("/auth/password", PasswordResetController, :request)

    # Portable Atomine anti-bot attestations
    get("/atomine/issuer", AtomineAttestationController, :issuer)
    post("/atomine/pow/challenge", AtomineAttestationController, :pow_challenge)
    post("/atomine/pow/receipts", AtomineAttestationController, :pow_receipt)
    post("/atomine/anonymous-tokens", AtomineAttestationController, :anonymous_token)

    post(
      "/atomine/anonymous-tokens/spend",
      AtomineAttestationController,
      :spend_anonymous_token
    )

    post(
      "/atomine/anonymous-tokens/redeem",
      AtomineAttestationController,
      :redeem_anonymous_token
    )

    post("/atomine/artifacts/verify", AtomineAttestationController, :verify)

    # Public client metadata
    post("/v1/apps", AppController, :create)
    get("/v1/apps/verify_credentials", AppController, :verify_credentials)
    get("/pleroma/frontend_configurations", UtilityController, :frontend_configurations)
    get("/v1/pleroma/frontend_configurations", UtilityController, :frontend_configurations)
    get("/v1/pleroma/preferred_frontend/available", UtilityController, :available_frontends)
    put("/v1/pleroma/preferred_frontend", UtilityController, :update_preferred_frontend)
    post("/v1/pleroma/password_reset", PasswordResetController, :confirm)
    get("/v1/pleroma/emoji", UtilityController, :emoji)
    get("/v1/pleroma/captcha", UtilityController, :captcha)
    get("/v1/pleroma/healthcheck", UtilityController, :healthcheck)
    get("/v1/pleroma/accounts/:id/scrobbles", ScrobbleController, :index)
    get("/v1/instance", InstanceController, :show_v1)
    get("/v1/instance/peers", InstanceController, :peers)
    get("/v1/instance/rules", InstanceController, :rules)
    get("/v1/instance/domain_blocks", InstanceController, :domain_blocks)
    get("/v1/instance/translation_languages", InstanceController, :translation_languages)
    get("/v2/instance", InstanceController, :show_v2)
    get("/v1/custom_emojis", CustomEmojiController, :index)
    get("/v1/directory", AccountDirectoryController, :index)
  end

  scope "/api", alias: false do
    pipe_through([:api, :api_rate_limited])

    post("/v1/accounts", ElektrineWeb.API.AccountRegistrationController, :create)
    post("/v1/accounts/password_reset", ElektrineWeb.API.PasswordResetController, :request)

    post(
      "/v1/accounts/password_reset/confirm",
      ElektrineWeb.API.PasswordResetController,
      :confirm
    )
  end

  scope "/api", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_account_read_scope])

    get("/v1/apps", ElektrineWeb.API.AppController, :index)
    get("/v1/pleroma/apps", ElektrineWeb.API.AppController, :index)
  end

  scope "/api", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_report_create_scope])

    post("/v1/reports", ElektrineWeb.API.ReportController, :create)
  end

  scope "/api", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_moderation_read_scope])

    get("/v1/reports", ElektrineWeb.API.ReportController, :index)
    get("/v1/reports/:id", ElektrineWeb.API.ReportController, :show)
    get("/v0/pleroma/reports", ElektrineWeb.API.ReportController, :index)
    get("/v0/pleroma/reports/:id", ElektrineWeb.API.ReportController, :show)
  end

  scope "/api", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_moderation_write_scope])

    put("/v1/reports/:id", ElektrineWeb.API.ReportController, :update)
    patch("/v1/reports/:id", ElektrineWeb.API.ReportController, :update)
    post("/v1/reports/:id/resolve", ElektrineWeb.API.ReportController, :resolve)
    post("/v1/reports/:id/dismiss", ElektrineWeb.API.ReportController, :dismiss)
    post("/v1/reports/:id/reopen", ElektrineWeb.API.ReportController, :reopen)
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

    put(
      "/pleroma/notification_settings",
      ElektrineWeb.API.SettingsController,
      :update_notifications
    )

    put(
      "/v1/pleroma/notification_settings",
      ElektrineWeb.API.SettingsController,
      :update_notifications
    )

    post("/pleroma/change_password", ElektrineWeb.API.SettingsController, :change_password)
    post("/v1/pleroma/change_password", ElektrineWeb.API.SettingsController, :change_password)
    post("/pleroma/change_email", ElektrineWeb.API.SettingsController, :change_email)
    post("/v1/pleroma/change_email", ElektrineWeb.API.SettingsController, :change_email)

    get("/pleroma/accounts/mfa", ElektrineWeb.API.TwoFactorAuthenticationController, :settings)
    get("/v1/pleroma/accounts/mfa", ElektrineWeb.API.TwoFactorAuthenticationController, :settings)

    get(
      "/pleroma/accounts/mfa/backup_codes",
      ElektrineWeb.API.TwoFactorAuthenticationController,
      :backup_codes
    )

    get(
      "/v1/pleroma/accounts/mfa/backup_codes",
      ElektrineWeb.API.TwoFactorAuthenticationController,
      :backup_codes
    )

    get(
      "/pleroma/accounts/mfa/setup/:method",
      ElektrineWeb.API.TwoFactorAuthenticationController,
      :setup
    )

    get(
      "/v1/pleroma/accounts/mfa/setup/:method",
      ElektrineWeb.API.TwoFactorAuthenticationController,
      :setup
    )

    post(
      "/pleroma/accounts/mfa/confirm/:method",
      ElektrineWeb.API.TwoFactorAuthenticationController,
      :confirm
    )

    post(
      "/v1/pleroma/accounts/mfa/confirm/:method",
      ElektrineWeb.API.TwoFactorAuthenticationController,
      :confirm
    )

    delete(
      "/pleroma/accounts/mfa/:method",
      ElektrineWeb.API.TwoFactorAuthenticationController,
      :disable
    )

    delete(
      "/v1/pleroma/accounts/mfa/:method",
      ElektrineWeb.API.TwoFactorAuthenticationController,
      :disable
    )

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
    get("/v1/pleroma/settings/:app", ElektrineWeb.API.SettingsController, :show_app)
    patch("/v1/pleroma/settings/:app", ElektrineWeb.API.SettingsController, :update_app)
    put("/v1/pleroma/settings/:app", ElektrineWeb.API.SettingsController, :update_app)
    get("/pleroma/aliases", ElektrineWeb.API.UtilityController, :list_aliases)
    put("/pleroma/aliases", ElektrineWeb.API.UtilityController, :add_alias)
    delete("/pleroma/aliases", ElektrineWeb.API.UtilityController, :delete_alias)
    post("/pleroma/move_account", ElektrineWeb.API.UtilityController, :move_account)
    get("/v1/notifications", ElektrineWeb.API.NotificationController, :v1_index)
    get("/v1/notifications/:id", ElektrineWeb.API.NotificationController, :show)
    post("/v1/notifications/clear", ElektrineWeb.API.NotificationController, :clear)

    post(
      "/v1/pleroma/notifications/read",
      ElektrineWeb.API.NotificationController,
      :mark_read_via_body
    )

    post("/v1/notifications/dismiss", ElektrineWeb.API.NotificationController, :dismiss_via_body)
    post("/v1/notifications/:id/dismiss", ElektrineWeb.API.NotificationController, :dismiss)

    delete(
      "/v1/notifications/destroy_multiple",
      ElektrineWeb.API.NotificationController,
      :destroy_multiple
    )

    get("/v2/notifications", ElektrineWeb.API.NotificationController, :v2_index)
    get("/v2/notifications/unread_count", ElektrineWeb.API.NotificationController, :unread_count)

    get(
      "/v2/notifications/:group_key/accounts",
      ElektrineWeb.API.NotificationController,
      :group_accounts
    )

    get("/v2/notifications/:group_key", ElektrineWeb.API.NotificationController, :show_group)

    post(
      "/v2/notifications/:group_key/dismiss",
      ElektrineWeb.API.NotificationController,
      :dismiss_group
    )

    get("/v1/push/subscription", ElektrineWeb.API.PushSubscriptionController, :show)
    post("/v1/push/subscription", ElektrineWeb.API.PushSubscriptionController, :create)
    put("/v1/push/subscription", ElektrineWeb.API.PushSubscriptionController, :update)
    delete("/v1/push/subscription", ElektrineWeb.API.PushSubscriptionController, :delete)

    # Timeline markers
    get("/markers", ElektrineWeb.API.MarkerController, :index)
    post("/markers", ElektrineWeb.API.MarkerController, :upsert)
    get("/v1/markers", ElektrineWeb.API.MarkerController, :index)
    post("/v1/markers", ElektrineWeb.API.MarkerController, :upsert)

    # Client preferences
    get("/v1/preferences", ElektrineWeb.API.PreferenceController, :show)

    # Suggested follows
    get("/v1/suggestions", ElektrineWeb.API.SuggestionController, :index)
    get("/v2/suggestions", ElektrineWeb.API.SuggestionController, :index)
    delete("/v2/suggestions/:account_id", ElektrineWeb.API.SuggestionController, :dismiss)

    # Search
    get("/v2/search", ElektrineWeb.API.SearchController, :index)

    # Account search and lookup
    get(
      "/v1/accounts/verify_credentials",
      ElektrineWeb.API.AccountCredentialController,
      :verify_credentials
    )

    patch(
      "/v1/accounts/update_credentials",
      ElektrineWeb.API.AccountCredentialController,
      :update_credentials
    )

    get("/v1/accounts/search", ElektrineWeb.API.AccountSearchController, :search)
    get("/v1/accounts/lookup", ElektrineWeb.API.AccountSearchController, :lookup)
    post("/v1/follows", ElektrineWeb.API.AccountRelationshipController, :follow_by_uri)

    get(
      "/v1/accounts/familiar_followers",
      ElektrineWeb.API.AccountRelationshipController,
      :familiar_followers
    )

    get(
      "/v1/accounts/relationships",
      ElektrineWeb.API.AccountRelationshipController,
      :relationships
    )

    get("/v1/endorsements", ElektrineWeb.API.AccountRelationshipController, :endorsements)
    get("/v1/pleroma/birthdays", ElektrineWeb.API.AccountBirthdayController, :index)
    get("/v1/accounts/:id", ElektrineWeb.API.AccountSearchController, :show)

    # Account statuses
    get("/v1/accounts/:id/statuses", ElektrineWeb.API.AccountStatusController, :index)
    get("/v1/accounts/:id/favourites", ElektrineWeb.API.AccountStatusController, :favourites)

    get(
      "/v1/pleroma/accounts/:id/favourites",
      ElektrineWeb.API.AccountStatusController,
      :favourites
    )

    get("/v1/accounts/:id/followers", ElektrineWeb.API.AccountRelationshipController, :followers)
    get("/v1/accounts/:id/following", ElektrineWeb.API.AccountRelationshipController, :following)

    get(
      "/v1/accounts/:id/endorsements",
      ElektrineWeb.API.AccountRelationshipController,
      :account_endorsements
    )

    get("/v1/accounts/:id/lists", ElektrineWeb.API.AccountRelationshipController, :lists)
    post("/v1/accounts/:id/follow", ElektrineWeb.API.AccountRelationshipController, :follow)
    post("/v1/accounts/:id/unfollow", ElektrineWeb.API.AccountRelationshipController, :unfollow)
    post("/v1/accounts/:id/subscribe", ElektrineWeb.API.AccountRelationshipController, :subscribe)

    post(
      "/v1/accounts/:id/unsubscribe",
      ElektrineWeb.API.AccountRelationshipController,
      :unsubscribe
    )

    post("/v1/accounts/:id/pin", ElektrineWeb.API.AccountRelationshipController, :endorse)
    post("/v1/accounts/:id/unpin", ElektrineWeb.API.AccountRelationshipController, :unendorse)
    post("/v1/accounts/:id/endorse", ElektrineWeb.API.AccountRelationshipController, :endorse)
    post("/v1/accounts/:id/unendorse", ElektrineWeb.API.AccountRelationshipController, :unendorse)

    post(
      "/v1/accounts/:id/remove_from_followers",
      ElektrineWeb.API.AccountRelationshipController,
      :remove_from_followers
    )

    # Status read/actions
    get("/v1/bookmarks", ElektrineWeb.API.BookmarkController, :index)
    get("/v1/favourites", ElektrineWeb.API.FavouriteController, :index)
    post("/v1/pleroma/scrobble", ElektrineWeb.API.ScrobbleController, :create)
    get("/v1/statuses", ElektrineWeb.API.StatusReadController, :index)
    post("/v1/statuses", ElektrineWeb.API.StatusActionController, :create)
    get("/v1/statuses/:id", ElektrineWeb.API.StatusReadController, :show)
    get("/v1/statuses/:id/context", ElektrineWeb.API.StatusReadController, :context)
    get("/v1/statuses/:id/favourited_by", ElektrineWeb.API.StatusReadController, :favourited_by)
    get("/v1/statuses/:id/reblogged_by", ElektrineWeb.API.StatusReadController, :reblogged_by)
    get("/v1/statuses/:id/quotes", ElektrineWeb.API.StatusReadController, :quotes)
    get("/v1/pleroma/statuses/:id/quotes", ElektrineWeb.API.StatusReadController, :quotes)
    get("/v1/statuses/:id/source", ElektrineWeb.API.StatusReadController, :source)
    get("/v1/statuses/:id/history", ElektrineWeb.API.StatusReadController, :history)
    get("/v1/statuses/:id/reactions", ElektrineWeb.API.StatusReactionController, :index)
    get("/v1/statuses/:id/reactions/:emoji", ElektrineWeb.API.StatusReactionController, :show)
    put("/v1/statuses/:id", ElektrineWeb.API.StatusActionController, :update)
    patch("/v1/statuses/:id", ElektrineWeb.API.StatusActionController, :update)
    delete("/v1/statuses/:id", ElektrineWeb.API.StatusActionController, :delete)
    put("/v1/statuses/:id/reactions/:emoji", ElektrineWeb.API.StatusReactionController, :create)

    delete(
      "/v1/statuses/:id/reactions/:emoji",
      ElektrineWeb.API.StatusReactionController,
      :delete
    )

    get("/v1/pleroma/statuses/:id/reactions", ElektrineWeb.API.StatusReactionController, :index)

    get(
      "/v1/pleroma/statuses/:id/reactions/:emoji",
      ElektrineWeb.API.StatusReactionController,
      :show
    )

    put(
      "/v1/pleroma/statuses/:id/reactions/:emoji",
      ElektrineWeb.API.StatusReactionController,
      :create
    )

    delete(
      "/v1/pleroma/statuses/:id/reactions/:emoji",
      ElektrineWeb.API.StatusReactionController,
      :delete
    )

    post("/v1/media", ElektrineWeb.API.MediaAttachmentController, :create)
    get("/v1/media/:id", ElektrineWeb.API.MediaAttachmentController, :show)
    put("/v1/media", ElektrineWeb.API.MediaAttachmentController, :update)
    patch("/v1/media", ElektrineWeb.API.MediaAttachmentController, :update)
    put("/v1/media/:id", ElektrineWeb.API.MediaAttachmentController, :update)
    patch("/v1/media/:id", ElektrineWeb.API.MediaAttachmentController, :update)
    post("/v2/media", ElektrineWeb.API.MediaAttachmentController, :create)
    get("/v2/media/:id", ElektrineWeb.API.MediaAttachmentController, :show)

    # Lists
    get("/v1/lists", ElektrineWeb.API.ListController, :index)
    post("/v1/lists", ElektrineWeb.API.ListController, :create)
    get("/v1/lists/:id", ElektrineWeb.API.ListController, :show)
    put("/v1/lists/:id", ElektrineWeb.API.ListController, :update)
    patch("/v1/lists/:id", ElektrineWeb.API.ListController, :update)
    delete("/v1/lists/:id", ElektrineWeb.API.ListController, :delete)
    get("/v1/lists/:id/accounts", ElektrineWeb.API.ListController, :accounts)
    post("/v1/lists/:id/accounts", ElektrineWeb.API.ListController, :add_accounts)
    delete("/v1/lists/:id/accounts", ElektrineWeb.API.ListController, :remove_accounts)

    post("/v1/statuses/:id/favourite", ElektrineWeb.API.StatusActionController, :favourite)
    post("/v1/statuses/:id/unfavourite", ElektrineWeb.API.StatusActionController, :unfavourite)
    post("/v1/statuses/:id/reblog", ElektrineWeb.API.StatusActionController, :reblog)
    post("/v1/statuses/:id/unreblog", ElektrineWeb.API.StatusActionController, :unreblog)
    post("/v1/statuses/:id/bookmark", ElektrineWeb.API.StatusActionController, :bookmark)
    post("/v1/statuses/:id/unbookmark", ElektrineWeb.API.StatusActionController, :unbookmark)
    post("/v1/statuses/:id/mute", ElektrineWeb.API.StatusActionController, :mute)
    post("/v1/statuses/:id/unmute", ElektrineWeb.API.StatusActionController, :unmute)
    post("/v1/statuses/:id/pin", ElektrineWeb.API.StatusPinController, :pin)
    post("/v1/statuses/:id/unpin", ElektrineWeb.API.StatusPinController, :unpin)
    post("/v1/statuses/:id/translate", ElektrineWeb.API.StatusActionController, :translate)

    # Direct conversations
    get("/v1/conversations", ElektrineWeb.API.DirectConversationController, :index)
    get("/v1/pleroma/conversations/:id", ElektrineWeb.API.DirectConversationController, :show)
    patch("/v1/pleroma/conversations/:id", ElektrineWeb.API.DirectConversationController, :update)

    get(
      "/v1/conversations/:id/statuses",
      ElektrineWeb.API.DirectConversationController,
      :statuses
    )

    get(
      "/v1/pleroma/conversations/:id/statuses",
      ElektrineWeb.API.DirectConversationController,
      :statuses
    )

    post(
      "/v1/pleroma/conversations/read",
      ElektrineWeb.API.DirectConversationController,
      :read_all
    )

    post("/v1/conversations/:id/read", ElektrineWeb.API.DirectConversationController, :read)
    delete("/v1/conversations/:id", ElektrineWeb.API.DirectConversationController, :delete)

    # System announcements
    get("/v1/announcements", ElektrineWeb.API.AnnouncementController, :index)
    post("/v1/announcements/:id/dismiss", ElektrineWeb.API.AnnouncementController, :dismiss)

    # Polls
    get("/v1/polls/:id", ElektrineWeb.API.PollController, :show)
    post("/v1/polls/:id/votes", ElektrineWeb.API.PollController, :vote)
    delete("/v1/polls/:id/votes", ElektrineWeb.API.PollController, :delete_votes)

    # Scheduled statuses
    get("/v1/scheduled_statuses", ElektrineWeb.API.ScheduledStatusController, :index)
    post("/v1/scheduled_statuses", ElektrineWeb.API.ScheduledStatusController, :create)
    get("/v1/scheduled_statuses/:id", ElektrineWeb.API.ScheduledStatusController, :show)
    put("/v1/scheduled_statuses/:id", ElektrineWeb.API.ScheduledStatusController, :update)
    patch("/v1/scheduled_statuses/:id", ElektrineWeb.API.ScheduledStatusController, :update)
    delete("/v1/scheduled_statuses/:id", ElektrineWeb.API.ScheduledStatusController, :delete)

    post(
      "/v1/scheduled_statuses/:id/publish",
      ElektrineWeb.API.ScheduledStatusController,
      :publish
    )

    # Timeline filters
    get("/v1/filters", ElektrineWeb.API.FilterController, :index)
    post("/v1/filters", ElektrineWeb.API.FilterController, :create)
    get("/v1/filters/:id", ElektrineWeb.API.FilterController, :show)
    put("/v1/filters/:id", ElektrineWeb.API.FilterController, :update)
    patch("/v1/filters/:id", ElektrineWeb.API.FilterController, :update)
    delete("/v1/filters/:id", ElektrineWeb.API.FilterController, :delete)

    # Tags
    get("/v1/timelines/direct", ElektrineWeb.API.TimelineController, :direct)
    get("/v1/timelines/home", ElektrineWeb.API.TimelineController, :home)
    get("/v1/timelines/public", ElektrineWeb.API.TimelineController, :public)
    get("/v1/timelines/list/:id", ElektrineWeb.API.ListController, :timeline)
    get("/v1/timelines/tag/:tag", ElektrineWeb.API.TagController, :timeline)
    get("/v1/trends", ElektrineWeb.API.TrendController, :tags)
    get("/v1/trends/tags", ElektrineWeb.API.TrendController, :tags)
    get("/v1/trends/statuses", ElektrineWeb.API.TrendController, :statuses)
    get("/v1/trends/links", ElektrineWeb.API.TrendController, :links)
    get("/v1/followed_tags", ElektrineWeb.API.TagController, :index_followed)
    get("/v1/tags/:id", ElektrineWeb.API.TagController, :show)
    post("/v1/tags/:id/follow", ElektrineWeb.API.TagController, :follow)
    post("/v1/tags/:id/unfollow", ElektrineWeb.API.TagController, :unfollow)

    # Account notes
    post("/v1/accounts/:id/note", ElektrineWeb.API.AccountNoteController, :create)

    # Account relationships
    get("/v1/mutes", ElektrineWeb.API.AccountRelationshipController, :mutes)
    get("/v1/blocks", ElektrineWeb.API.AccountRelationshipController, :blocks)
    get("/v1/domain_blocks", ElektrineWeb.API.DomainBlockController, :index)
    post("/v1/domain_blocks", ElektrineWeb.API.DomainBlockController, :create)
    delete("/v1/domain_blocks", ElektrineWeb.API.DomainBlockController, :delete)
    post("/v1/accounts/:id/mute", ElektrineWeb.API.AccountRelationshipController, :mute)
    post("/v1/accounts/:id/unmute", ElektrineWeb.API.AccountRelationshipController, :unmute)
    post("/v1/accounts/:id/block", ElektrineWeb.API.AccountRelationshipController, :block)
    post("/v1/accounts/:id/unblock", ElektrineWeb.API.AccountRelationshipController, :unblock)

    # Follow requests
    get("/v1/follow_requests", ElektrineWeb.API.FollowRequestController, :index)

    post(
      "/v1/follow_requests/:id/authorize",
      ElektrineWeb.API.FollowRequestController,
      :authorize
    )

    post("/v1/follow_requests/:id/reject", ElektrineWeb.API.FollowRequestController, :reject)

    get(
      "/v1/pleroma/outgoing_follow_requests",
      ElektrineWeb.API.OutgoingFollowRequestController,
      :index
    )

    delete(
      "/v1/pleroma/outgoing_follow_requests/:id",
      ElektrineWeb.API.OutgoingFollowRequestController,
      :cancel
    )

    post("/v1/pleroma/import", ElektrineWeb.API.RelationshipImportController, :create)
    post("/pleroma/follow_import", ElektrineWeb.API.RelationshipImportController, :follow_import)

    post(
      "/v1/pleroma/follow_import",
      ElektrineWeb.API.RelationshipImportController,
      :follow_import
    )

    post("/pleroma/mutes_import", ElektrineWeb.API.RelationshipImportController, :mutes_import)
    post("/v1/pleroma/mutes_import", ElektrineWeb.API.RelationshipImportController, :mutes_import)
    post("/pleroma/blocks_import", ElektrineWeb.API.RelationshipImportController, :blocks_import)

    post(
      "/v1/pleroma/blocks_import",
      ElektrineWeb.API.RelationshipImportController,
      :blocks_import
    )

    # Chat client compatibility
    post(
      "/v1/pleroma/chats/by-account-id/:id",
      ElektrineWeb.API.ChatCompatController,
      :create_by_account
    )

    get("/v1/pleroma/chats", ElektrineWeb.API.ChatCompatController, :index)
    get("/v1/pleroma/chats/:id", ElektrineWeb.API.ChatCompatController, :show)
    get("/v1/pleroma/chats/:id/messages", ElektrineWeb.API.ChatCompatController, :messages)
    post("/v1/pleroma/chats/:id/messages", ElektrineWeb.API.ChatCompatController, :post_message)

    delete(
      "/v1/pleroma/chats/:id/messages/:message_id",
      ElektrineWeb.API.ChatCompatController,
      :delete_message
    )

    post("/v1/pleroma/chats/:id/read", ElektrineWeb.API.ChatCompatController, :read)

    post(
      "/v1/pleroma/chats/:id/messages/:message_id/read",
      ElektrineWeb.API.ChatCompatController,
      :read_message
    )

    post("/v1/pleroma/chats/:id/pin", ElektrineWeb.API.ChatCompatController, :pin)
    post("/v1/pleroma/chats/:id/unpin", ElektrineWeb.API.ChatCompatController, :unpin)
    get("/v2/pleroma/chats", ElektrineWeb.API.ChatCompatController, :index)

    # Client-compatible bookmark folders
    get("/v1/pleroma/bookmark_folders", ElektrineWeb.API.BookmarkFolderController, :index)
    post("/v1/pleroma/bookmark_folders", ElektrineWeb.API.BookmarkFolderController, :create)
    patch("/v1/pleroma/bookmark_folders/:id", ElektrineWeb.API.BookmarkFolderController, :update)
    delete("/v1/pleroma/bookmark_folders/:id", ElektrineWeb.API.BookmarkFolderController, :delete)

    # Client-compatible account backups
    get("/pleroma/backups", ElektrineWeb.API.BackupController, :index)
    post("/pleroma/backups", ElektrineWeb.API.BackupController, :create)
    get("/pleroma/backups/:id", ElektrineWeb.API.BackupController, :show)
    delete("/pleroma/backups/:id", ElektrineWeb.API.BackupController, :delete)

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

  scope "/api/ext/v1/proofs", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_proofs_read_scope])

    get("/", ProofController, :index)
    get("/score", ProofController, :score)
    get("/:id", ProofController, :show)
  end

  scope "/api/ext/v1/proofs", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_proofs_write_scope])

    post("/", ProofController, :create)
    post("/:id/check", ProofController, :check)
    delete("/:id", ProofController, :delete)
  end

  scope "/api/ext/v1/static-site", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_static_site_read_scope])

    get("/", StaticSiteController, :show)
  end

  scope "/api/ext/v1/static-site", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_static_site_write_scope])

    post("/deploy", StaticSiteController, :deploy)
  end

  scope "/api/ext/v1/static-site", ElektrineWeb.API do
    pipe_through([:api, :api_rate_limited])

    post("/deploy/github", StaticSiteController, :deploy_github)
    post("/deploy/github/webhook", StaticSiteController, :github_webhook)
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

  scope "/api/ext/v1/nerve", ElektrineWeb.API do
    pipe_through([:api_nerve_authenticated, :api_pat_nerve_read_scope])

    ElektrineWeb.Routes.Nerve.api_read_routes()
  end

  scope "/api/ext/v1/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_read_scope])

    ElektrineWeb.Routes.DNS.api_read_routes()
  end

  scope "/api/ext/v1/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_write_scope])

    ElektrineWeb.Routes.DNS.api_write_routes()
  end

  scope "/api/ext/v1/nerve", ElektrineWeb.API do
    pipe_through([:api_nerve_authenticated, :api_pat_nerve_write_scope])

    ElektrineWeb.Routes.Nerve.api_write_routes()
  end

  scope "/api/ext/v1/kairo", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_kairo_read_scope])

    get("/projects", KairoController, :projects)
    get("/sources", KairoController, :sources)
    get("/sources/:id", KairoController, :source)
  end

  scope "/api/ext/v1/kairo", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_kairo_write_scope])

    post("/projects", KairoController, :create_project)
    post("/sources", KairoController, :create_source)
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

  scope "/api/ext/nerve", ElektrineWeb.API do
    pipe_through([:api_nerve_authenticated, :api_pat_nerve_read_scope])

    ElektrineWeb.Routes.Nerve.api_read_routes()
  end

  scope "/api/ext/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_read_scope])

    ElektrineWeb.Routes.DNS.api_read_routes()
  end

  scope "/api/ext/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_write_scope])

    ElektrineWeb.Routes.DNS.api_write_routes()
  end

  scope "/api/ext/nerve", ElektrineWeb.API do
    pipe_through([:api_nerve_authenticated, :api_pat_nerve_write_scope])

    ElektrineWeb.Routes.Nerve.api_write_routes()
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
    pipe_through([
      :browser,
      :require_vpn_when_netbird_enabled,
      :require_admin_host,
      :require_admin_access
    ])

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
        {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user},
        {ElektrineWeb.Live.Hooks.PlatformModuleHook, :default},
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
        ElektrineWeb.Routes.Uptime.main_live_routes()
      end

      # Portal
      live("/portal", PortalLive.Index, :index)
      live("/maid", SearchLive, :index)
      live("/kairo", KairoLive.Index, :index)
      live("/proofs", AtomineProofsLive.Show, :index)
      live("/proofs/:handle", AtomineProofsLive.Show, :show)

      # Subscription pages
      live("/subscribe/:product", SubscribeLive, :index)

      # === Authenticated routes (auth checked in mount via current_user assign) ===

      # Account settings
      live("/account", UserSettingsLive)
      live("/account/password", SettingsLive.EditPassword, :edit)
      live("/account/two_factor/setup", SettingsLive.TwoFactorSetup, :setup)
      live("/account/two_factor", SettingsLive.TwoFactorManage, :manage)
      live("/account/passkeys", SettingsLive.PasskeyManage, :manage)
      live("/account/master-password", SettingsLive.MasterPassword, :index)
      live("/account/delete", SettingsLive.DeleteAccount, :delete)

      # Profile editing
      live("/account/profile/edit", ProfileLive.Edit, :edit)
      live("/domains", ProfileLive.Domains, :index)
      live("/analytics/profile", ProfileLive.Analytics, :analytics)
      live("/analytics/domains", ProfileLive.DomainAnalytics, :analytics)
      live("/account/storage", StorageLive)
      live("/account/drive", DriveLive)
      live("/account/proofs", ProofsLive)

      live("/friends", FriendsLive, :index)

      # Notifications
      live("/notifications", NotificationsLive, :index)

      # Settings
      live("/account/app-passwords", SettingsLive.AppPasswords)

      get(
        "/account/nerve/extension/:browser/download",
        NerveExtensionController,
        :download
      )

      ElektrineWeb.Routes.Nerve.live_routes()

      live("/settings/rss", SettingsLive.RSS, :index)

      live("/dns/analytics", ProfileLive.DomainAnalytics, :analytics)

      # Backward-compatible app search route. /maid is the canonical merged search UI.
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

    # Post-notification subscription / endorsement / private note actions
    # (static-page form fallbacks for the LiveView bell/star/note buttons)
    post("/profiles/:handle/subscribe", ProfileController, :subscribe)
    delete("/profiles/:handle/subscribe", ProfileController, :unsubscribe)
    post("/profiles/:handle/endorse", ProfileController, :endorse)
    delete("/profiles/:handle/endorse", ProfileController, :unendorse)
    post("/profiles/:handle/note", ProfileController, :save_account_note)
  end

  # Profile page - Renders static HTML profile
  # Used for subdomain access (username.<profile-domain>) and SEO
  # IMPORTANT: This catch-all route MUST be last in the router
  scope "/", ElektrineWeb do
    pipe_through(:browser)

    get("/:handle", ProfileController, :show)
  end
end
