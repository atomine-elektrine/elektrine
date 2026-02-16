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
    # RSS feed fetching
    rss: 2,
    # Data exports (low priority, can take time)
    exports: 2,
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
       # Clean up old failed deliveries daily at 3 AM
       {"0 3 * * *", Elektrine.ActivityPub.DeliveryCleanupWorker},
       # Re-enqueue pending federation deliveries when next_retry_at is due
       {"* * * * *", Elektrine.ActivityPub.DeliveryRetryWorker},
       # Check for stale RSS feeds every 15 minutes
       {"*/15 * * * *", Elektrine.RSS.SchedulerWorker},
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
       # Archive/prune federation event/outbox data daily
       {"20 2 * * *", Elektrine.Messaging.FederationRetentionWorker}
     ]}
  ]

# Explicitly use UTC-only timezone database to avoid breaking DateTime.add
# Timezone conversions use Tzdata explicitly in shift_zone/3
config :elixir, :time_zone_database, Calendar.UTCOnlyTimeZoneDatabase

# Configure email settings
config :elektrine, :email,
  domain: System.get_env("EMAIL_DOMAIN") || "elektrine.com",
  # Legacy receiver webhook auth fallback:
  # keep permissive in dev/test, fail-closed in prod unless explicitly configured.
  allow_insecure_receiver_webhook: config_env() != :prod,
  # Supported domains for multi-domain access
  supported_domains: [
    "elektrine.com",
    "z.org"
  ]

# Configure Giphy API
config :elektrine, :giphy,
  api_key: System.get_env("GIPHY_API_KEY"),
  base_url: "https://api.giphy.com/v1"

# Configure ACME
# Use :staging for testing, :production for real certificates
config :elektrine, :acme_environment, :staging
config :elektrine, :acme_contact_email, "admin@elektrine.com"
# ACME account key path - in production uses /data/certs/acme/, in dev uses tmp
config :elektrine, :acme_account_key_path, "/tmp/elektrine/acme/account_key.pem"

# Export directory for user data exports - in production uses /data/exports/, in dev uses tmp
config :elektrine, :export_dir, "/tmp/elektrine/exports"

# WebAuthn/Passkey configuration
# These defaults are for development; override in runtime.exs for production
config :elektrine,
  passkey_rp_id: "localhost",
  passkey_origin: "http://localhost:4000"

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

# Quantum scheduler configuration
config :elektrine, Elektrine.Scheduler,
  jobs: [
    # Deactivate expired announcements every hour
    {"0 * * * *", {Elektrine.Admin, :deactivate_expired_announcements, []}},
    # Recalculate discussion scores every 6 hours (reduced from hourly)
    {"0 */6 * * *", {Elektrine.Social, :recalculate_recent_discussion_scores, []}},
    # Recategorize emails every 30 minutes (reduced from 5 minutes)
    {"*/30 * * * *", {Elektrine.Jobs.EmailRecategorizer, :run, []}},
    # Process reply later messages every 5 minutes (reduced from every minute)
    {"*/5 * * * *", {Elektrine.Jobs.ReplyLaterProcessor, :run, []}},
    # DISABLED: StorageRecalculator - too expensive, causes pool exhaustion
    # {"0 * * * *", {Elektrine.Jobs.StorageRecalculator, :run, []}},
    # Clean up stale calls every 30 minutes (reduced from 5 minutes)
    {"*/30 * * * *", {Elektrine.Jobs.StaleCallCleanup, :run, []}},
    # Auto-promote users based on trust level requirements (daily at 3 AM)
    {"0 3 * * *", {Elektrine.Accounts.TrustLevel, :auto_promote_eligible_users, []}}
  ]

# S3-compatible storage configuration (Cloudflare R2, AWS S3, etc.)
# Configure in runtime.exs for production
config :elektrine, :uploads,
  adapter: :s3,
  # Upload security limits
  # 5MB
  max_file_size: 5 * 1024 * 1024,
  max_image_width: 2048,
  max_image_height: 2048

# Messaging federation (Discord-lite, self-hosted peer sync)
# Keep disabled by default; enable and configure peers in runtime config.
config :elektrine, :messaging_federation,
  enabled: false,
  identity_key_id: "default",
  delivery_concurrency: 6,
  delivery_timeout_ms: 12_000,
  outbox_max_attempts: 8,
  outbox_base_backoff_seconds: 5,
  event_retention_days: 14,
  outbox_retention_days: 30,
  peers: []

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
