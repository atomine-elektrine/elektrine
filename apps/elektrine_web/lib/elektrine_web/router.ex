defmodule ElektrineWeb.Router do
  use ElektrineWeb, :router

  import ElektrineWeb.UserAuth
  require ElektrinePasswordManagerWeb.Routes

  @default_profile_host_scope "*.#{Application.compile_env(:elektrine, :primary_domain, "example.com")}"

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
    plug(ElektrineWeb.Plugs.OptionalDelegate, module: ElektrineEmailWeb.Plugs.JMAPAuth)
    plug(ElektrineWeb.Plugs.APIRateLimit)
  end

  pipeline :jmap_discovery do
    # JMAP discovery (authenticated)
    plug(:accepts, ["json"])
    plug(ElektrineWeb.Plugs.RequirePlatformModule)
    plug(ElektrineWeb.Plugs.OptionalDelegate, module: ElektrineEmailWeb.Plugs.JMAPAuth)
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

    get("/:signature/:encoded_url", ElektrineSocialWeb.MediaProxyController, :proxy)
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

  # Email client autodiscovery
  scope "/.well-known/autoconfig/mail", ElektrineWeb do
    pipe_through(:autoconfig)

    get("/config-v1.1.xml", AutoconfigController, :mozilla_autoconfig)
  end

  scope "/.well-known", ElektrineWeb do
    pipe_through(:well_known_text)

    get("/mta-sts.txt", MailSecurityController, :mta_sts)
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

  scope "/files-dav", ElektrineWeb.DAV do
    pipe_through(:dav)

    match(:propfind, "/:username", FilesController, :propfind_home)
    match(:propfind, "/:username/*path", FilesController, :propfind_resource)
    match(:mkcol, "/:username/*path", FilesController, :mkcol)
    match(:move, "/:username/*path", FilesController, :move_resource)
    get("/:username/*path", FilesController, :get_file)
    put("/:username/*path", FilesController, :put_file)
    delete("/:username/*path", FilesController, :delete_resource)
  end

  # WKD (Web Key Directory) for PGP public key discovery
  scope "/.well-known/openpgpkey", alias: false do
    pipe_through(:api)

    # Direct method: /.well-known/openpgpkey/hu/{hash}
    get("/hu/:hash", ElektrineEmailWeb.WKDController, :get_key)
    # Policy file
    get("/policy", ElektrineEmailWeb.WKDController, :policy)
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
  scope "/addressbooks", ElektrineEmailWeb.DAV do
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
  scope "/.well-known", ElektrineEmailWeb.JMAP do
    pipe_through(:jmap_discovery)

    get("/jmap", SessionController, :session)
  end

  scope "/.well-known", ElektrineWeb do
    pipe_through(:well_known_text)

    get("/atproto-did", BlueskyIdentityController, :well_known_did)
  end

  # JMAP API (RFC 8620, RFC 8621)
  scope "/jmap", ElektrineEmailWeb.JMAP do
    pipe_through(:jmap)

    post("/", APIController, :api)
    get("/eventsource", EventSourceController, :eventsource)
    get("/download/:account_id/:blob_id/:name", BlobController, :download)
    post("/upload/:account_id", BlobController, :upload)
  end

  # ActivityPub federation routes
  scope "/.well-known", alias: false do
    pipe_through(:activitypub)

    get("/webfinger", ElektrineSocialWeb.WebFingerController, :webfinger)
    get("/host-meta", ElektrineSocialWeb.WebFingerController, :host_meta)
    get("/nodeinfo", ElektrineSocialWeb.NodeinfoController, :well_known)
  end

  # Nodeinfo endpoints (outside .well-known scope)
  scope "/nodeinfo", alias: false do
    pipe_through(:activitypub)

    get("/2.0", ElektrineSocialWeb.NodeinfoController, :nodeinfo_2_0)
    get("/2.1", ElektrineSocialWeb.NodeinfoController, :nodeinfo_2_1)
  end

  # Routes that don't require authentication (MOVED BEFORE ActivityPub to prioritize browser requests)
  scope "/", ElektrineWeb do
    pipe_through(:browser)

    # SEO
    get("/sitemap.xml", SitemapController, :index)
    get("/robots.txt", SitemapController, :robots)

    scope "/", alias: false do
      # ActivityPub external interaction compatibility (Lemmy/Mastodon clients)
      get("/authorize_interaction", ElektrineSocialWeb.ExternalInteractionController, :show)

      get(
        "/activitypub/externalInteraction",
        ElektrineSocialWeb.ExternalInteractionController,
        :show
      )

      # Unsubscribe routes (RFC 8058 support) - POST routes stay as controllers
      post("/unsubscribe/:token", ElektrineEmailWeb.UnsubscribeController, :one_click)
      post("/unsubscribe/confirm/:token", ElektrineEmailWeb.UnsubscribeController, :confirm)
      post("/resubscribe", ElektrineEmailWeb.UnsubscribeController, :resubscribe)
    end

    # Temporary email routes disabled
    # Guest temporary mail system has been disabled for security

    # Link click tracking and redirect
    get("/l/:id", LinkController, :click)

    # Public file shares
    get("/files/share/:token", FileShareController, :show)
    post("/files/share/:token", FileShareController, :authorize)
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
  scope "/users/:username", alias: false do
    pipe_through(:activitypub)

    get("/", ElektrineSocialWeb.ActivityPubController, :actor)
    post("/inbox", ElektrineSocialWeb.ActivityPubController, :inbox)
    get("/outbox", ElektrineSocialWeb.ActivityPubController, :outbox)
    get("/followers", ElektrineSocialWeb.ActivityPubController, :followers)
    get("/following", ElektrineSocialWeb.ActivityPubController, :following)
    get("/statuses/:id", ElektrineSocialWeb.ActivityPubController, :object)
  end

  # ActivityPub community (Group) routes - Use /c/ prefix to avoid conflict with /communities/ LiveView
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

  # Relay actor inbox (for receiving Accept/Reject from relays)
  scope "/relay", alias: false do
    pipe_through(:activitypub)

    get("/", ElektrineSocialWeb.ActivityPubController, :relay_actor)
    post("/inbox", ElektrineSocialWeb.ActivityPubController, :inbox)
  end

  # Shared inbox for federation
  scope "/", alias: false do
    pipe_through(:activitypub)

    post("/inbox", ElektrineSocialWeb.ActivityPubController, :inbox)
  end

  # Hashtag collection endpoint for federation
  scope "/tags", alias: false do
    pipe_through(:activitypub)

    get("/:name", ElektrineSocialWeb.ActivityPubController, :hashtag_collection)
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
      # Email attachment downloads
      get(
        "/email/message/:message_id/attachment/:attachment_id/download",
        ElektrineEmailWeb.AttachmentController,
        :download
      )

      # Email controller routes
      delete("/email/:id", ElektrineEmailWeb.EmailController, :delete)
      get("/email/:id/print", ElektrineEmailWeb.EmailController, :print)
      get("/email/:id/download_eml", ElektrineEmailWeb.EmailController, :download_eml)
      get("/email/:id/iframe_content", ElektrineEmailWeb.EmailController, :iframe_content)
      get("/email/export/download/:id", ElektrineEmailWeb.EmailController, :download_export)
    end

    # Personal file downloads
    get("/account/files/:id/download", FilesController, :download)
    get("/account/files/:id/preview", FilesController, :preview)

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
      # Alias management
      get("/aliases", ElektrineEmailWeb.Admin.AliasesController, :index)
      post("/aliases/:id/toggle", ElektrineEmailWeb.Admin.AliasesController, :toggle)
      delete("/aliases/:id", ElektrineEmailWeb.Admin.AliasesController, :delete)
      get("/forwarded-messages", ElektrineEmailWeb.Admin.AliasesController, :forwarded_messages)

      # Mailbox management
      get("/mailboxes", ElektrineEmailWeb.Admin.MailboxesController, :index)
      delete("/mailboxes/:id", ElektrineEmailWeb.Admin.MailboxesController, :delete)
      get("/custom-domains", ElektrineEmailWeb.Admin.CustomDomainsController, :index)

      # Message management
      get("/messages", ElektrineEmailWeb.Admin.MessagesController, :index)
      get("/messages/:id/view", ElektrineEmailWeb.Admin.MessagesController, :view)
      get("/messages/:id/raw", ElektrineEmailWeb.Admin.MessagesController, :view_raw)
      get("/users/:id/messages", ElektrineEmailWeb.Admin.MessagesController, :user_messages)

      get(
        "/users/:user_id/messages/:id",
        ElektrineEmailWeb.Admin.MessagesController,
        :view_user_message
      )

      get(
        "/users/:user_id/messages/:id/raw",
        ElektrineEmailWeb.Admin.MessagesController,
        :view_user_message_raw
      )

      get("/messages/:id/iframe", ElektrineEmailWeb.Admin.MessagesController, :iframe)

      # Arblarg chat message management
      get("/arblarg/messages", ElektrineChatWeb.Admin.ChatMessagesController, :index)
      get("/arblarg/messages/:id/view", ElektrineChatWeb.Admin.ChatMessagesController, :view)
      get("/arblarg/messages/:id/raw", ElektrineChatWeb.Admin.ChatMessagesController, :view_raw)
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

    scope "/", alias: false do
      # VPN management
      get("/vpn", ElektrineVPNWeb.Admin.VPNController, :dashboard)
      get("/vpn/servers/new", ElektrineVPNWeb.Admin.VPNController, :new_server)
      post("/vpn/servers", ElektrineVPNWeb.Admin.VPNController, :create_server)
      get("/vpn/servers/:id/edit", ElektrineVPNWeb.Admin.VPNController, :edit_server)

      get(
        "/vpn/servers/:id/confirm-delete",
        ElektrineVPNWeb.Admin.VPNController,
        :confirm_delete_server
      )

      put("/vpn/servers/:id", ElektrineVPNWeb.Admin.VPNController, :update_server)
      delete("/vpn/servers/:id", ElektrineVPNWeb.Admin.VPNController, :delete_server)
      get("/vpn/users", ElektrineVPNWeb.Admin.VPNController, :users)
      get("/vpn/users/:id/edit", ElektrineVPNWeb.Admin.VPNController, :edit_user_config)
      put("/vpn/users/:id", ElektrineVPNWeb.Admin.VPNController, :update_user_config)
      post("/vpn/users/:id/reset-quota", ElektrineVPNWeb.Admin.VPNController, :reset_user_quota)
    end
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

  # OAuth token endpoints (no auth required for token exchange)
  scope "/oauth", ElektrineSocialWeb.MastodonAPI do
    pipe_through(:api)

    post("/token", OAuthController, :token)
    post("/revoke", OAuthController, :revoke)
  end

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

  # Mastodon API v1 - Public endpoints (no auth required)
  scope "/api/v1", ElektrineSocialWeb.MastodonAPI do
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
  scope "/api/v2", ElektrineSocialWeb.MastodonAPI do
    pipe_through(:mastodon_api)

    get("/instance", InstanceController, :show_v2)
  end

  # Mastodon API v1 - Authenticated endpoints
  scope "/api/v1", ElektrineSocialWeb.MastodonAPI do
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
  scope "/api", alias: false do
    pipe_through(:api)

    # Email API endpoints
    post("/haraka/inbound", ElektrineEmailWeb.HarakaWebhookController, :create)
    post("/haraka/verify-recipient", ElektrineEmailWeb.HarakaWebhookController, :verify_recipient)
    post("/haraka/auth", ElektrineEmailWeb.HarakaWebhookController, :auth)
    get("/haraka/domains", ElektrineEmailWeb.HarakaWebhookController, :domains)

    # VPN API endpoints (called by WireGuard servers)
    post("/vpn/register", ElektrineVPNWeb.VPNAPIController, :auto_register)
    get("/vpn/:server_id/peers", ElektrineVPNWeb.VPNAPIController, :get_peers)
    post("/vpn/:server_id/stats", ElektrineVPNWeb.VPNAPIController, :update_stats)
    post("/vpn/:server_id/heartbeat", ElektrineVPNWeb.VPNAPIController, :heartbeat)
    post("/vpn/:server_id/connection", ElektrineVPNWeb.VPNAPIController, :log_connection)
    post("/vpn/:server_id/register-key", ElektrineVPNWeb.VPNAPIController, :register_key)
    post("/vpn/:server_id/check-peer", ElektrineVPNWeb.VPNAPIController, :check_peer)
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
    get("/vpn/servers", ElektrineVPNWeb.API.VPNController, :index)
    get("/vpn/configs", ElektrineVPNWeb.API.VPNController, :list_configs)
    get("/vpn/configs/:id", ElektrineVPNWeb.API.VPNController, :show_config)
    post("/vpn/configs", ElektrineVPNWeb.API.VPNController, :create_config)
    delete("/vpn/configs/:id", ElektrineVPNWeb.API.VPNController, :delete_config)

    # Email API endpoints
    get("/emails", ElektrineEmailWeb.API.EmailController, :index)
    get("/emails/search", ElektrineEmailWeb.API.EmailController, :search)
    get("/emails/counts", ElektrineEmailWeb.API.EmailController, :counts)
    post("/emails/bulk", ElektrineEmailWeb.API.EmailController, :bulk_action)
    get("/emails/:id", ElektrineEmailWeb.API.EmailController, :show)
    get("/emails/:id/attachments", ElektrineEmailWeb.API.EmailController, :list_attachments)

    get(
      "/emails/:id/attachments/:attachment_id",
      ElektrineEmailWeb.API.EmailController,
      :attachment
    )

    post("/emails/send", ElektrineEmailWeb.API.EmailController, :send_email)
    put("/emails/:id", ElektrineEmailWeb.API.EmailController, :update)
    put("/emails/:id/category", ElektrineEmailWeb.API.EmailController, :update_category)
    put("/emails/:id/reply-later", ElektrineEmailWeb.API.EmailController, :set_reply_later)
    delete("/emails/:id", ElektrineEmailWeb.API.EmailController, :delete)

    # Alias management
    get("/aliases", ElektrineEmailWeb.API.AliasController, :index)
    post("/aliases", ElektrineEmailWeb.API.AliasController, :create)
    get("/aliases/:id", ElektrineEmailWeb.API.AliasController, :show)
    put("/aliases/:id", ElektrineEmailWeb.API.AliasController, :update)
    delete("/aliases/:id", ElektrineEmailWeb.API.AliasController, :delete)

    # Mailbox info
    get("/mailbox", ElektrineEmailWeb.API.MailboxController, :show)
    get("/mailbox/stats", ElektrineEmailWeb.API.MailboxController, :stats)

    # Device registration for push notifications
    get("/devices", ElektrineWeb.API.DeviceController, :index)
    post("/devices", ElektrineWeb.API.DeviceController, :create)
    delete("/devices/:token", ElektrineWeb.API.DeviceController, :delete)

    # Notifications
    get("/notifications", ElektrineWeb.API.NotificationController, :index)
    post("/notifications/:id/read", ElektrineWeb.API.NotificationController, :mark_read)
    post("/notifications/read-all", ElektrineWeb.API.NotificationController, :mark_all_read)
    delete("/notifications/:id", ElektrineWeb.API.NotificationController, :dismiss)

    # Chat/Messaging API
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

    # Conversation actions
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

    # Conversation members
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

    # Messages
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

    # Chat media upload
    post(
      "/conversations/:conversation_id/upload",
      ElektrineChatWeb.API.ConversationController,
      :upload_media
    )

    # Message reactions
    post("/messages/:message_id/reactions", ElektrineChatWeb.API.MessageController, :add_reaction)

    delete(
      "/messages/:message_id/reactions/:emoji",
      ElektrineChatWeb.API.MessageController,
      :remove_reaction
    )

    # Social/Timeline API
    get("/social/timeline", ElektrineSocialWeb.API.SocialController, :timeline)
    get("/social/timeline/public", ElektrineSocialWeb.API.SocialController, :public_timeline)

    # Posts
    get("/social/posts/:id", ElektrineSocialWeb.API.SocialController, :show_post)
    post("/social/posts", ElektrineSocialWeb.API.SocialController, :create_post)
    delete("/social/posts/:id", ElektrineSocialWeb.API.SocialController, :delete_post)

    # Post interactions
    post("/social/posts/:id/like", ElektrineSocialWeb.API.SocialController, :like_post)
    delete("/social/posts/:id/like", ElektrineSocialWeb.API.SocialController, :unlike_post)
    post("/social/posts/:id/repost", ElektrineSocialWeb.API.SocialController, :repost)
    delete("/social/posts/:id/repost", ElektrineSocialWeb.API.SocialController, :unrepost)

    # Comments
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
    delete("/social/comments/:id/like", ElektrineSocialWeb.API.SocialController, :unlike_comment)

    # Following
    get("/social/followers", ElektrineSocialWeb.API.SocialController, :list_followers)
    get("/social/following", ElektrineSocialWeb.API.SocialController, :list_following)

    # User profiles and actions
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
    delete("/social/users/:user_id/block", ElektrineSocialWeb.API.SocialController, :unblock_user)

    # Friend requests
    get("/social/friend-requests", ElektrineSocialWeb.API.SocialController, :list_friend_requests)

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

    # Communities
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
    post("/social/communities/:id/join", ElektrineSocialWeb.API.SocialController, :join_community)

    delete(
      "/social/communities/:id/join",
      ElektrineSocialWeb.API.SocialController,
      :leave_community
    )

    # Media upload
    post("/social/upload", ElektrineSocialWeb.API.SocialController, :upload_media)

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

    get("/messages", ElektrineEmailWeb.API.ExtEmailController, :index)
    get("/messages/:id", ElektrineEmailWeb.API.ExtEmailController, :show)
  end

  scope "/api/ext/v1/email", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_email_write_scope])

    post("/messages", ElektrineEmailWeb.API.ExtEmailController, :create)
  end

  scope "/api/ext/v1/chat", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_chat_read_scope])

    get("/conversations", ElektrineChatWeb.API.ExtChatController, :index)
    get("/conversations/:id", ElektrineChatWeb.API.ExtChatController, :show)
    get("/conversations/:id/messages", ElektrineChatWeb.API.ExtChatController, :messages)
  end

  scope "/api/ext/v1/chat", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_chat_write_scope])

    post("/conversations/:id/messages", ElektrineChatWeb.API.ExtChatController, :create)
  end

  scope "/api/ext/v1/social", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_social_read_scope])

    get("/feed", ElektrineSocialWeb.API.ExtSocialController, :feed)
    get("/posts/:id", ElektrineSocialWeb.API.ExtSocialController, :show)
    get("/users/:user_id/posts", ElektrineSocialWeb.API.ExtSocialController, :user_posts)
  end

  scope "/api/ext/v1/social", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_social_write_scope])

    post("/posts", ElektrineSocialWeb.API.ExtSocialController, :create)
  end

  scope "/api/ext/v1/contacts", alias: false do
    pipe_through([:api_pat_authenticated, :api_pat_contacts_read_scope])

    get("/", ElektrineEmailWeb.API.ExtContactsController, :index)
    get("/:id", ElektrineEmailWeb.API.ExtContactsController, :show)
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

    ElektrinePasswordManagerWeb.Routes.api_read_routes()
  end

  scope "/api/ext/v1/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_read_scope])

    scope "/", alias: false do
      get("/zones", ElektrineDNSWeb.API.DNSController, :index)
      get("/zones/:id", ElektrineDNSWeb.API.DNSController, :show)
    end
  end

  scope "/api/ext/v1/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_write_scope])

    scope "/", alias: false do
      post("/zones", ElektrineDNSWeb.API.DNSController, :create)
      put("/zones/:id", ElektrineDNSWeb.API.DNSController, :update)
      delete("/zones/:id", ElektrineDNSWeb.API.DNSController, :delete)
      post("/zones/:id/verify", ElektrineDNSWeb.API.DNSController, :verify)

      post(
        "/zones/:id/services/:service/apply",
        ElektrineDNSWeb.API.DNSController,
        :apply_service
      )

      delete("/zones/:id/services/:service", ElektrineDNSWeb.API.DNSController, :disable_service)
      post("/zones/:zone_id/records", ElektrineDNSWeb.API.DNSController, :create_record)
      put("/zones/:zone_id/records/:id", ElektrineDNSWeb.API.DNSController, :update_record)
      delete("/zones/:zone_id/records/:id", ElektrineDNSWeb.API.DNSController, :delete_record)
    end
  end

  scope "/api/ext/v1/password-manager", ElektrineWeb.API do
    pipe_through([:api_vault_authenticated, :api_pat_vault_write_scope])

    ElektrinePasswordManagerWeb.Routes.api_write_routes()
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

  scope "/api/ext/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_read_scope])

    scope "/", alias: false do
      get("/zones", ElektrineDNSWeb.API.DNSController, :index)
      get("/zones/:id", ElektrineDNSWeb.API.DNSController, :show)
    end
  end

  scope "/api/ext/dns", ElektrineWeb.API do
    pipe_through([:api_pat_authenticated, :api_pat_dns_write_scope])

    scope "/", alias: false do
      post("/zones", ElektrineDNSWeb.API.DNSController, :create)
      put("/zones/:id", ElektrineDNSWeb.API.DNSController, :update)
      delete("/zones/:id", ElektrineDNSWeb.API.DNSController, :delete)
      post("/zones/:id/verify", ElektrineDNSWeb.API.DNSController, :verify)

      post(
        "/zones/:id/services/:service/apply",
        ElektrineDNSWeb.API.DNSController,
        :apply_service
      )

      delete("/zones/:id/services/:service", ElektrineDNSWeb.API.DNSController, :disable_service)
      post("/zones/:zone_id/records", ElektrineDNSWeb.API.DNSController, :create_record)
      put("/zones/:zone_id/records/:id", ElektrineDNSWeb.API.DNSController, :update_record)
      delete("/zones/:zone_id/records/:id", ElektrineDNSWeb.API.DNSController, :delete_record)
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

      scope "/", alias: false do
        live("/vpn/policy", ElektrineVPNWeb.PageLive.VPNPolicy, :index)
      end

      if Application.compile_env(:elektrine, :dev_routes) do
        # Flash testing page (LiveView path)
        live("/dev/flash-test", PageLive.DevFlashTest, :index)
      end

      scope "/", alias: false do
        # Unsubscribe (GET only - POST stays as controller)
        live("/unsubscribe/:token", ElektrineEmailWeb.UnsubscribeLive.Show, :show)

        # Communities (formerly Discussions)
        live("/communities", ElektrineSocialWeb.DiscussionsLive.Index, :index)
        live("/communities/:name", ElektrineSocialWeb.DiscussionsLive.Community, :show)
        live("/communities/:name/settings", ElektrineSocialWeb.DiscussionsLive.Settings, :index)
        live("/communities/:name/post/:post_id", ElektrineSocialWeb.DiscussionsLive.Post, :show)

        # Legacy redirects (backwards compatibility)
        live("/discussions", ElektrineSocialWeb.DiscussionsLive.Index, :index)
        live("/discussions/:name", ElektrineSocialWeb.DiscussionsLive.Community, :show)
        live("/discussions/:name/settings", ElektrineSocialWeb.DiscussionsLive.Settings, :index)
        live("/discussions/:name/post/:post_id", ElektrineSocialWeb.DiscussionsLive.Post, :show)

        # Timeline
        live("/timeline", ElektrineSocialWeb.TimelineLive.Index, :index)
        live("/timeline/post/:id", ElektrineSocialWeb.TimelineLive.Post, :show)
        live("/hashtag/:hashtag", ElektrineSocialWeb.HashtagLive.Show, :show)

        # Lists
        live("/lists", ElektrineSocialWeb.ListLive.Index, :index)
        live("/lists/:id", ElektrineSocialWeb.ListLive.Show, :show)

        # Gallery
        live("/gallery", ElektrineSocialWeb.GalleryLive.Index, :index)

        # Remote user profiles
        live("/remote/:handle", ElektrineSocialWeb.RemoteUserLive.Show, :show)

        # Remote post detail
        live("/remote/post/:post_id", ElektrineSocialWeb.RemotePostLive.Show, :show)

        # Chat/Messaging
        live("/chat", ElektrineChatWeb.ChatLive.Index, :index)
        live("/chat/:conversation_id", ElektrineChatWeb.ChatLive.Index, :conversation)
        live("/chat/join/:conversation_id", ElektrineChatWeb.ChatLive.Index, :join)

        # Email
        live("/email", ElektrineEmailWeb.EmailLive.Index, :index)
        live("/email/compose", ElektrineEmailWeb.EmailLive.Compose, :new)
        live("/email/view/:id", ElektrineEmailWeb.EmailLive.Show, :show)
        live("/email/:id/raw", ElektrineEmailWeb.EmailLive.Raw)
        live("/email/search", ElektrineEmailWeb.EmailLive.Search, :search)
        live("/email/settings", ElektrineEmailWeb.EmailLive.Settings, :index)

        # VPN
        live("/vpn", ElektrineVPNWeb.VPNLive.Index, :index)

        # DNS
        live("/dns", ElektrineDNSWeb.DNSLive.Index, :index)

        # Contacts
        live("/contacts", ElektrineEmailWeb.ContactsLive.Index, :index)
        live("/contacts/:id", ElektrineEmailWeb.ContactsLive.Index, :show)

        # Calendar
        live("/calendar", ElektrineEmailWeb.EmailLive.Index, :calendar)
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
      live("/account/files", FilesLive)

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

      ElektrinePasswordManagerWeb.Routes.live_routes()

      live("/settings/rss", SettingsLive.RSS, :index)

      live("/dns/analytics", DNSLive.Analytics, :analytics)

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
