# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elektrine,
  ecto_repos: [Elektrine.Repo],
  generators: [timestamp_type: :utc_datetime]

config :elektrine,
  # In production this is enabled in runtime.exs.
  enforce_https: false,
  # Allow HTTP Basic Auth only in local development/testing when explicitly enabled there.
  allow_insecure_dav_jmap_auth: false,
  # Empty by default: no proxy headers are trusted unless explicitly configured.
  trusted_proxy_cidrs: []

# Oban background job processing
# Worker counts optimized with Lemmy-style per-domain throttling
config :elektrine, Oban,
  repo: Elektrine.Repo,
  queues: [
    default: 3,
    # Incoming ActivityPub processing - kept very low to prevent DB overload
    # Each worker does multiple DB queries during activity processing
    activitypub: 1,
    # Outgoing ActivityPub delivery - also reduced
    activitypub_delivery: 2,
    # Email sending
    email: 2,
    # Inbound Haraka processing
    email_inbound: 2,
    # RSS feed fetching
    rss: 2,
    # Data exports (low priority, can take time)
    exports: 2,
    # Outbound developer webhook deliveries
    webhooks: 2,
    # Federation metadata fetching (nodeinfo, favicons)
    federation_metadata: 2,
    # Federated timeline background refresh/ingestion workers
    federation: 2,
    # Messaging federation outbox/event delivery
    messaging_federation: 4
  ],
  plugins: [
    # Keep jobs for 1 day only
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24},
    # Rescue stuck jobs
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       # Deactivate expired announcements every hour
       {"0 * * * *", Elektrine.Jobs.DeactivateExpiredAnnouncementsWorker},
       # Clean up old failed deliveries daily at 3 AM
       {"0 3 * * *", Elektrine.ActivityPub.DeliveryCleanupWorker},
       # Auto-promote users based on trust level requirements daily
       {"0 3 * * *", Elektrine.Jobs.AutoPromoteEligibleUsersWorker},
       # Re-enqueue pending federation deliveries when next_retry_at is due
       {"* * * * *", Elektrine.ActivityPub.DeliveryRetryWorker},
       # Check for stale RSS feeds every 15 minutes
       {"*/15 * * * *", Elektrine.RSS.SchedulerWorker},
       # Recalculate discussion scores every 6 hours
       {"0 */6 * * *", Elektrine.Jobs.RecalculateRecentDiscussionScoresWorker},
       # Recategorize recent email every 30 minutes
       {"*/30 * * * *", Elektrine.Jobs.EmailRecategorizer},
       # Process due reply-later messages every 5 minutes
       {"*/5 * * * *", Elektrine.Jobs.ReplyLaterProcessor},
       # Clean up stale calls every 30 minutes
       {"*/30 * * * *", Elektrine.Jobs.StaleCallCleanup},
       # Re-enqueue due messaging federation outbox rows
       {"* * * * *", Elektrine.Messaging.FederationOutboxRetryWorker},
       # Refresh counts for recent federated posts hourly
       {"5 * * * *", Elektrine.ActivityPub.RefreshCountsWorker,
        args: %{"type" => "refresh_recent"}},
       # Refresh counts for popular federated posts every 4 hours
       {"15 */4 * * *", Elektrine.ActivityPub.RefreshCountsWorker,
        args: %{"type" => "refresh_popular"}},
       # Refresh counts for recently interacted federated posts every 30 minutes
       {"*/30 * * * *", Elektrine.ActivityPub.RefreshCountsWorker,
        args: %{"type" => "refresh_interacted"}},
       # Poll Bluesky notifications for mirrored post replies/mentions
       {"*/2 * * * *", Elektrine.Bluesky.InboundPollWorker},
       # Archive/prune federation event/outbox data daily
       {"20 2 * * *", Elektrine.Messaging.FederationRetentionWorker}
     ]}
  ]

# Explicitly use UTC-only timezone database to avoid breaking DateTime.add
# Timezone conversions use Tzdata explicitly in shift_zone/3
config :elixir, :time_zone_database, Calendar.UTCOnlyTimeZoneDatabase

primary_domain =
  (System.get_env("PRIMARY_DOMAIN") || "elektrine.com")
  |> String.trim()
  |> String.downcase()

email_domain =
  (System.get_env("EMAIL_DOMAIN") || primary_domain)
  |> String.trim()
  |> String.downcase()

supported_domains_env =
  System.get_env("SUPPORTED_DOMAINS") || System.get_env("EMAIL_SUPPORTED_DOMAINS")

default_supported_domains = [email_domain]

normalize_domains = fn domains ->
  domains
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.map(&String.downcase/1)
  |> Enum.uniq()
end

configured_supported_domains =
  case supported_domains_env do
    nil ->
      default_supported_domains

    value ->
      String.split(value, ",", trim: true)
  end

supported_email_domains =
  ([primary_domain] ++ configured_supported_domains)
  |> normalize_domains.()

profile_domains_env = System.get_env("PROFILE_BASE_DOMAINS")

profile_base_domains =
  case profile_domains_env do
    nil ->
      [primary_domain]

    value ->
      ([primary_domain] ++ String.split(value, ",", trim: true))
      |> normalize_domains.()
  end

profile_host_scope =
  case profile_base_domains do
    [domain | _] -> "*.#{domain}"
    _ -> "*.#{primary_domain}"
  end

# Configure email settings
config :elektrine, :email,
  domain: email_domain,
  # Legacy receiver webhook auth fallback:
  # keep permissive in dev/test, fail-closed in prod unless explicitly configured.
  allow_insecure_receiver_webhook: config_env() != :prod,
  # Supported domains for multi-domain access
  supported_domains: supported_email_domains,
  custom_domain_mx_host: primary_domain,
  custom_domain_mx_priority: 10,
  custom_domain_spf_include: nil,
  custom_domain_dkim_selector: "default",
  custom_domain_dkim_sync_enabled: true,
  custom_domain_haraka_base_url: nil,
  custom_domain_haraka_api_key: nil,
  custom_domain_haraka_timeout: 10_000,
  custom_domain_haraka_dkim_path: "/api/v1/dkim/domains",
  custom_domain_http_client: Elektrine.Email.DKIM.FinchClient,
  custom_domain_dmarc_policy: "quarantine",
  custom_domain_dmarc_adkim: "s",
  custom_domain_dmarc_aspf: "s",
  custom_domain_dmarc_rua: nil

config :elektrine, :dns,
  authority_enabled: false,
  recursive_enabled: false,
  udp_port: 5300,
  tcp_port: 5300,
  nameservers: [],
  soa_rname: nil,
  recursive_timeout: 3000,
  recursive_root_hints: [
    {{198, 41, 0, 4}, 53},
    {{170, 247, 170, 2}, 53},
    {{192, 33, 4, 12}, 53},
    {{199, 7, 91, 13}, 53},
    {{192, 203, 230, 10}, 53},
    {{192, 5, 5, 241}, 53},
    {{192, 112, 36, 4}, 53},
    {{198, 97, 190, 53}, 53},
    {{192, 36, 148, 17}, 53},
    {{192, 58, 128, 30}, 53},
    {{193, 0, 14, 129}, 53},
    {{199, 7, 83, 42}, 53},
    {{202, 12, 27, 33}, 53}
  ],
  recursive_allow_cidrs: [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "::1/128",
    "fc00::/7"
  ],
  default_ttl: 300

config :elektrine, :profile_base_domains, profile_base_domains
config :elektrine, :profile_host_scope, profile_host_scope
config :elektrine, :primary_domain, primary_domain

config :elektrine, :compiled_platform_modules, [:chat, :social, :email, :vault, :vpn, :dns]

config :elektrine, :platform_modules, enabled: [:chat, :social, :email, :vault, :vpn, :dns]

# Process Haraka inbound payloads asynchronously through Oban.
# Can be overridden with HARAKA_ASYNC_INGEST at runtime.
config :elektrine, :haraka_async_ingest, true

# Automatically suppress outbound recipients after verified hard bounces/FBL complaints.
# Can be overridden with EMAIL_AUTO_SUPPRESSION at runtime.
config :elektrine, :email_auto_suppression, true

# Configure Giphy API
config :elektrine, :giphy,
  api_key: System.get_env("GIPHY_API_KEY"),
  base_url: "https://api.giphy.com/v1"

# Export directory for user data exports - in production uses /data/exports/, in dev uses tmp
config :elektrine, :export_dir, "/tmp/elektrine/exports"

# WebAuthn/Passkey configuration
# These defaults are for development; override in runtime.exs for production
config :elektrine,
  passkey_rp_id: "localhost",
  passkey_origin: "http://localhost:4000"

# Admin web security controls
# - passkey-bound admin sessions
# - short-lived elevation windows
# - per-action passkey confirmation grants
config :elektrine, :admin_security,
  require_passkey: true,
  access_ttl_seconds: 15 * 60,
  elevation_ttl_seconds: 5 * 60,
  action_grant_ttl_seconds: 90,
  intent_ttl_seconds: 3 * 60,
  replay_ttl_seconds: 10 * 60

# Configure WebRTC STUN/TURN servers
config :elektrine, :webrtc,
  ice_servers: [
    # Free Google STUN servers
    %{urls: ["stun:stun.l.google.com:19302"]},
    %{urls: ["stun:stun1.l.google.com:19302"]},
    # Twilio STUN (free)
    %{urls: ["stun:global.stun.twilio.com:3478"]}
    # Add your own TURN server in runtime.exs or environment config
    # %{
    #   urls: ["turn:your-turn-server.com:3478"],
    #   username: System.get_env("TURN_USERNAME"),
    #   credential: System.get_env("TURN_CREDENTIAL")
    # }
  ]

# Configures the endpoint
config :elektrine, ElektrineWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ElektrineWeb.ErrorHTML, json: ElektrineWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Elektrine.PubSub,
  live_view: [signing_salt: "ewG/v8k5"]

# Configures the mailer
#
# Use SMTP adapter as a placeholder - we'll override in runtime
config :elektrine, Elektrine.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  elektrine: [
    args:
      ~w(js/app.js js/error_page.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/elektrine/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (using npm-installed version for reliable builds)
config :tailwind,
  version: "4.1.18",
  path: Path.expand("../apps/elektrine/assets/node_modules/.bin/tailwindcss", __DIR__),
  elektrine: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/elektrine/assets", __DIR__),
    # Use inotify directly instead of trying watchman first (avoids "watchman: not found" error)
    env: %{"PARCEL_WATCHER_BACKEND" => "inotify"}
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Gettext
config :elektrine, ElektrineWeb.Gettext,
  default_locale: "en",
  locales: ~w(en zh)

# Configure Swoosh API client
config :swoosh, :api_client, Swoosh.ApiClient.Hackney

# S3-compatible storage configuration (Cloudflare R2, AWS S3, etc.)
# Configure in runtime.exs for production
config :elektrine, :uploads,
  adapter: :s3,
  # Upload security limits
  # 5MB
  max_file_size: 5 * 1024 * 1024,
  max_image_width: 2048,
  max_image_height: 2048

# Messaging federation (community-style, self-hosted peer sync)
# Enabled by default; configure peers and identity material in runtime config.
config :elektrine, :messaging_federation,
  enabled: true,
  identity_key_id: "default",
  identity_keys: [],
  identity_shared_secret: nil,
  official_relay_operator: "Community-operated",
  official_relays: [],
  conformance_core_passed: true,
  conformance_extensions: %{
    "urn:arbp:ext:roles:1" => true,
    "urn:arbp:ext:permissions:1" => true,
    "urn:arbp:ext:threads:1" => true,
    "urn:arbp:ext:presence:1" => true,
    "urn:arbp:ext:moderation:1" => true
  },
  clock_skew_seconds: 300,
  allow_insecure_http_transport: false,
  delivery_concurrency: 6,
  delivery_timeout_ms: 12_000,
  outbox_max_attempts: 8,
  outbox_base_backoff_seconds: 5,
  event_retention_days: 14,
  outbox_retention_days: 30,
  peers: []

# Bluesky outbound bridge (cross-post local public timeline posts)
# Keep disabled by default.
config :elektrine, :bluesky,
  enabled: false,
  service_url: "https://bsky.social",
  timeout_ms: 12_000,
  max_chars: 300,
  inbound_enabled: false,
  inbound_limit: 50,
  managed_enabled: false,
  managed_service_url: nil,
  managed_domain: nil,
  managed_admin_password: nil

# Cloudflare Turnstile configuration
config :elektrine, :turnstile,
  site_key: System.get_env("TURNSTILE_SITE_KEY"),
  secret_key: System.get_env("TURNSTILE_SECRET_KEY"),
  verify_url: "https://challenges.cloudflare.com/turnstile/v0/siteverify"

# Stripe configuration (defaults for development, override in runtime.exs)
config :stripity_stripe,
  api_key: nil,
  signing_secret: nil

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
