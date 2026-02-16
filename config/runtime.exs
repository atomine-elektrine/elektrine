import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/elektrine start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :elektrine, ElektrineWeb.Endpoint, server: true
end

# Lightweight messaging federation runtime configuration
messaging_federation_enabled =
  case System.get_env("MESSAGING_FEDERATION_ENABLED", "false") do
    value when value in ["1", "true", "TRUE", "yes", "YES"] -> true
    _ -> false
  end

messaging_federation_peers =
  case System.get_env("MESSAGING_FEDERATION_PEERS_JSON") do
    nil ->
      []

    "" ->
      []

    json ->
      case Jason.decode(json) do
        {:ok, peers} when is_list(peers) -> peers
        _ -> []
      end
  end

messaging_federation_identity_key_id =
  case System.get_env("MESSAGING_FEDERATION_IDENTITY_KEY_ID") do
    nil -> "default"
    "" -> "default"
    value -> value
  end

parse_int_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      default

    value ->
      case Integer.parse(value) do
        {int, ""} when int > 0 -> int
        _ -> default
      end
  end
end

messaging_federation_delivery_concurrency =
  parse_int_env.("MESSAGING_FEDERATION_DELIVERY_CONCURRENCY", 6)

messaging_federation_delivery_timeout_ms =
  parse_int_env.("MESSAGING_FEDERATION_DELIVERY_TIMEOUT_MS", 12_000)

messaging_federation_outbox_max_attempts =
  parse_int_env.("MESSAGING_FEDERATION_OUTBOX_MAX_ATTEMPTS", 8)

messaging_federation_outbox_base_backoff_seconds =
  parse_int_env.("MESSAGING_FEDERATION_OUTBOX_BASE_BACKOFF_SECONDS", 5)

messaging_federation_event_retention_days =
  parse_int_env.("MESSAGING_FEDERATION_EVENT_RETENTION_DAYS", 14)

messaging_federation_outbox_retention_days =
  parse_int_env.("MESSAGING_FEDERATION_OUTBOX_RETENTION_DAYS", 30)

config :elektrine, :messaging_federation,
  enabled: messaging_federation_enabled,
  identity_key_id: messaging_federation_identity_key_id,
  delivery_concurrency: messaging_federation_delivery_concurrency,
  delivery_timeout_ms: messaging_federation_delivery_timeout_ms,
  outbox_max_attempts: messaging_federation_outbox_max_attempts,
  outbox_base_backoff_seconds: messaging_federation_outbox_base_backoff_seconds,
  event_retention_days: messaging_federation_event_retention_days,
  outbox_retention_days: messaging_federation_outbox_retention_days,
  peers: messaging_federation_peers

# Default OFF for local-first timeline performance.
timeline_remote_enrichment_enabled =
  case System.get_env("TIMELINE_REMOTE_ENRICHMENT", "false") do
    value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] -> false
    _ -> true
  end

config :elektrine, :timeline_remote_enrichment, timeline_remote_enrichment_enabled

# Configure Haraka HTTP API adapter if EMAIL_SERVICE is set to haraka (any environment)
if System.get_env("EMAIL_SERVICE") == "haraka" do
  config :elektrine, Elektrine.Mailer,
    adapter: Elektrine.Email.HarakaAdapter,
    api_key: System.get_env("HARAKA_API_KEY"),
    base_url: System.get_env("HARAKA_BASE_URL", "https://haraka.elektrine.com"),
    timeout: 30_000

  # Enable API client for Haraka
  config :swoosh, :api_client, Swoosh.ApiClient.Hackney
end

# Configure encryption (all environments)
# Generate secrets with: mix phx.gen.secret 64
if config_env() == :prod do
  # In production, require encryption secrets - fail hard if missing
  config :elektrine,
    encryption_master_secret:
      System.get_env("ENCRYPTION_MASTER_SECRET") ||
        raise("ENCRYPTION_MASTER_SECRET environment variable is required in production!"),
    encryption_key_salt:
      System.get_env("ENCRYPTION_KEY_SALT") ||
        raise("ENCRYPTION_KEY_SALT environment variable is required in production!"),
    encryption_search_salt:
      System.get_env("ENCRYPTION_SEARCH_SALT") ||
        raise("ENCRYPTION_SEARCH_SALT environment variable is required in production!")
else
  # In development/test, generate random secrets for security
  # This prevents accidental use of static test secrets
  config :elektrine,
    encryption_master_secret:
      System.get_env("ENCRYPTION_MASTER_SECRET") ||
        Base.encode64(:crypto.strong_rand_bytes(32)),
    encryption_key_salt:
      System.get_env("ENCRYPTION_KEY_SALT") ||
        Base.encode64(:crypto.strong_rand_bytes(16)),
    encryption_search_salt:
      System.get_env("ENCRYPTION_SEARCH_SALT") ||
        Base.encode64(:crypto.strong_rand_bytes(16))
end

if config_env() == :prod do
  config :elektrine, :environment, :prod
  config :elektrine, :enforce_https, true
  config :elektrine, :allow_insecure_dav_jmap_auth, false

  trusted_proxy_cidrs =
    System.get_env("TRUSTED_PROXY_CIDRS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  config :elektrine, :trusted_proxy_cidrs, trusted_proxy_cidrs

  # Production paths - use persistent /data volume
  config :elektrine, :acme_account_key_path, "/data/certs/acme/account_key.pem"
  config :elektrine, :export_dir, "/data/exports"

  # Configure Sentry at runtime so releases read the deploy-time DSN.
  config :sentry,
    dsn: System.get_env("SENTRY_DSN"),
    environment_name: config_env(),
    enable_source_code_context: true,
    root_source_code_paths: [File.cwd!()],
    # Filter out benign errors that don't indicate actual problems
    before_send: {Elektrine.SentryFilter, :filter_event}

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  database_uri = URI.parse(database_url)

  database_query_params =
    if database_uri.query, do: URI.decode_query(database_uri.query), else: %{}

  ecto_ipv6 =
    case System.get_env("ECTO_IPV6") do
      nil -> not is_nil(System.get_env("FLY_APP_NAME"))
      value -> value in ~w(true 1)
    end

  maybe_ipv6 = if ecto_ipv6, do: [:inet6], else: []

  db_ssl_server_name =
    case System.get_env("DATABASE_SSL_SERVER_NAME") do
      nil -> database_uri.host
      "" -> database_uri.host
      hostname -> hostname
    end

  db_ssl_verify =
    case System.get_env("DATABASE_SSL_VERIFY") do
      nil ->
        case Map.get(database_query_params, "sslmode") do
          "disable" -> "none"
          _ -> "peer"
        end

      value ->
        String.downcase(value)
    end

  db_ssl_opts =
    case db_ssl_verify do
      "none" ->
        [verify: :verify_none]

      "peer" ->
        if is_nil(db_ssl_server_name) do
          raise """
          DATABASE_SSL_VERIFY=peer requires a database hostname.
          Set DATABASE_SSL_SERVER_NAME or include a host in DATABASE_URL.
          """
        end

        [
          verify: :verify_peer,
          server_name_indication: String.to_charlist(db_ssl_server_name),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

      value ->
        raise """
        invalid DATABASE_SSL_VERIFY value: #{value}
        Expected one of: peer, none
        """
    end

  db_ssl_opts =
    case System.get_env("DATABASE_SSL_CACERTFILE") do
      nil ->
        if db_ssl_verify == "peer" do
          default_cacertfile =
            [
              "/etc/ssl/certs/ca-certificates.crt",
              "/etc/pki/tls/certs/ca-bundle.crt",
              "/etc/ssl/cert.pem"
            ]
            |> Enum.find(&File.exists?/1)

          case default_cacertfile do
            nil -> db_ssl_opts
            path -> Keyword.put(db_ssl_opts, :cacertfile, path)
          end
        else
          db_ssl_opts
        end

      "" ->
        db_ssl_opts

      cacertfile ->
        Keyword.put(db_ssl_opts, :cacertfile, cacertfile)
    end

  db_prepare =
    case System.get_env("DB_PREPARE", "named") |> String.downcase() do
      "named" ->
        :named

      "unnamed" ->
        :unnamed

      value ->
        raise """
        invalid DB_PREPARE value: #{value}
        Expected one of: named, unnamed
        """
    end

  db_application_name =
    case System.get_env("DB_APPLICATION_NAME") do
      nil -> "elektrine"
      "" -> "elektrine"
      value -> value
    end

  env_int = fn name, default ->
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> int
          _ -> default
        end
    end
  end

  pool_size = env_int.("POOL_SIZE", 20)
  queue_target_ms = env_int.("DB_QUEUE_TARGET_MS", 2_000)
  queue_interval_ms = env_int.("DB_QUEUE_INTERVAL_MS", 5_000)
  query_timeout_ms = env_int.("DB_TIMEOUT_MS", 30_000)
  pool_timeout_ms = env_int.("DB_POOL_TIMEOUT_MS", 15_000)
  connect_timeout_ms = env_int.("DB_CONNECT_TIMEOUT_MS", 15_000)
  ap_inbox_max_per_ip_per_minute = env_int.("AP_INBOX_MAX_PER_IP_PER_MINUTE", 20)
  ap_inbox_max_per_domain_per_minute = env_int.("AP_INBOX_MAX_PER_DOMAIN_PER_MINUTE", 40)
  ap_inbox_max_global_per_second = env_int.("AP_INBOX_MAX_GLOBAL_PER_SECOND", 8)

  # SSL configuration for PostgreSQL.
  # Defaults to certificate verification (DATABASE_SSL_VERIFY=peer).
  # To disable verification for private-network deployments, set DATABASE_SSL_VERIFY=none.
  config :elektrine, Elektrine.Repo,
    ssl: db_ssl_opts,
    url: database_url,
    pool_size: pool_size,
    queue_target: queue_target_ms,
    queue_interval: queue_interval_ms,
    timeout: query_timeout_ms,
    pool_timeout: pool_timeout_ms,
    connect_timeout: connect_timeout_ms,
    socket_options: maybe_ipv6 ++ [keepalive: true],
    prepare: db_prepare,
    parameters: [application_name: db_application_name]

  config :elektrine, Elektrine.ActivityPub.InboxRateLimiter,
    max_per_minute: ap_inbox_max_per_ip_per_minute,
    max_per_domain_per_minute: ap_inbox_max_per_domain_per_minute,
    max_global_per_second: ap_inbox_max_global_per_second

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Validate session encryption salt at runtime (fail-closed security)
  session_encryption_salt =
    System.get_env("SESSION_ENCRYPTION_SALT") ||
      raise """
      environment variable SESSION_ENCRYPTION_SALT is missing.
      Session encryption is required in production for security.
      Generate a secure salt: mix phx.gen.secret 64
      Set it in Fly.io: fly secrets set SESSION_ENCRYPTION_SALT=your_secret
      """

  session_signing_salt =
    System.get_env("SESSION_SIGNING_SALT") ||
      raise """
      environment variable SESSION_SIGNING_SALT is missing.
      Session signing is required in production for security.
      Generate a secure salt: mix phx.gen.secret 64
      Set it in Fly.io: fly secrets set SESSION_SIGNING_SALT=your_secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :elektrine, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Allowed origins for WebSocket connections
  # Includes primary domains, subdomains, and fly.dev for staging
  allowed_origins = [
    "https://elektrine.com",
    "https://www.elektrine.com",
    "//*.elektrine.com",
    "https://z.org",
    "https://www.z.org",
    "//*.z.org",
    "//*.onion",
    "https://elektrine.fly.dev",
    "//*.fly.dev"
  ]

  # App-managed SSL with Let's Encrypt
  # Certificates are stored on persistent volume and managed by the app
  if System.get_env("LETS_ENCRYPT_ENABLED") == "true" do
    # Certificate paths - use existing certs or bootstrap self-signed
    # Real certs are at /data/certs/live/{domain}/
    # Bootstrap cert is at /data/certs/bootstrap/
    real_cert = "/data/certs/live/#{host}/fullchain.pem"
    real_key = "/data/certs/live/#{host}/privkey.pem"
    bootstrap_cert = "/data/certs/bootstrap/cert.pem"
    bootstrap_key = "/data/certs/bootstrap/key.pem"

    # Use real cert if it exists, otherwise use bootstrap
    # The bootstrap cert is generated at startup if needed
    {cert_path, keyfile} =
      if File.exists?(real_cert) && File.exists?(real_key) do
        {real_cert, real_key}
      else
        # Ensure bootstrap cert exists (generated by startup task)
        # For now, just use the paths - the cert will be created before endpoint starts
        {bootstrap_cert, bootstrap_key}
      end

    # HTTPS options with SNI callback for dynamic certificate selection
    # SNI allows serving different certificates based on the requested hostname
    # Use non-privileged ports (8443/8080) internally, fly.toml maps external 443/80 to these
    # For Bandit, TLS options like sni_fun must be under thousand_island_options
    https_opts = [
      port: 8443,
      cipher_suite: :strong,
      certfile: cert_path,
      keyfile: keyfile,
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      http_1_options: [
        max_header_count: 50,
        max_header_length: 8_192
      ],
      # SNI callback for main domains and known subdomains
      # Bandit passes this through to ThousandIsland's TLS options
      thousand_island_options: [
        transport_options: [
          sni_fun: &Elektrine.CustomDomains.SSLConfig.sni_fun/1
        ]
      ]
    ]

    config :elektrine, ElektrineWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      https: https_opts,
      http: [
        port: 8080,
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        http_1_options: [
          max_header_count: 50,
          max_header_length: 8_192
        ]
      ],
      secret_key_base: secret_key_base,
      live_view: [signing_salt: session_signing_salt],
      check_origin: allowed_origins
  else
    # HTTP-only configuration (for development or behind a proxy)
    config :elektrine, ElektrineWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: port,
        http_1_options: [
          max_header_count: 50,
          max_header_length: 8_192
        ]
      ],
      secret_key_base: secret_key_base,
      check_origin: allowed_origins
  end

  # Verify session encryption salt is properly set (not the build-time placeholder)
  if session_encryption_salt == "compile_time_placeholder_will_be_overridden_at_runtime" do
    raise """
    SESSION_ENCRYPTION_SALT is still using the build-time placeholder.
    You must set this environment variable in production.
    Generate: mix phx.gen.secret 64
    Set in Fly.io: fly secrets set SESSION_ENCRYPTION_SALT=your_generated_secret
    """
  end

  if session_signing_salt == "compile_time_placeholder_signing" do
    raise """
    SESSION_SIGNING_SALT is still using the build-time placeholder.
    You must set this environment variable in production.
    Generate: mix phx.gen.secret 64
    Set in Fly.io: fly secrets set SESSION_SIGNING_SALT=your_generated_secret
    """
  end

  # WebAuthn/Passkey configuration for production
  # Uses the PHX_HOST environment variable for RP ID
  config :elektrine,
    passkey_rp_id: host,
    passkey_origin: "https://#{host}"

  # Cloudflare Turnstile configuration for production
  config :elektrine, :turnstile,
    site_key:
      System.get_env("TURNSTILE_SITE_KEY") ||
        raise("""
        environment variable TURNSTILE_SITE_KEY is missing.
        Get your site key from https://dash.cloudflare.com/
        """),
    secret_key:
      System.get_env("TURNSTILE_SECRET_KEY") ||
        raise("""
        environment variable TURNSTILE_SECRET_KEY is missing.
        Get your secret key from https://dash.cloudflare.com/
        """),
    verify_url: "https://challenges.cloudflare.com/turnstile/v0/siteverify"

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :elektrine, ElektrineWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :elektrine, ElektrineWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.

  # Cloudflare R2 configuration for production
  config :ex_aws,
    access_key_id:
      System.get_env("R2_ACCESS_KEY_ID") ||
        raise("""
        environment variable R2_ACCESS_KEY_ID is missing.
        Get your Access Key ID from Cloudflare R2 dashboard.
        """),
    secret_access_key:
      System.get_env("R2_SECRET_ACCESS_KEY") ||
        raise("""
        environment variable R2_SECRET_ACCESS_KEY is missing.
        Get your Secret Access Key from Cloudflare R2 dashboard.
        """),
    region: "auto",
    json_codec: Jason,
    s3: [
      scheme: "https://",
      host:
        System.get_env("R2_ENDPOINT") ||
          raise("""
          environment variable R2_ENDPOINT is missing.
          Example: <account-id>.r2.cloudflarestorage.com
          """),
      region: "auto",
      port: 443
    ]

  config :elektrine, :uploads,
    adapter: :s3,
    bucket:
      System.get_env("R2_BUCKET_NAME") ||
        raise("""
        environment variable R2_BUCKET_NAME is missing.
        Set your Cloudflare R2 bucket name.
        """),
    endpoint:
      System.get_env("R2_ENDPOINT") ||
        raise("""
        environment variable R2_ENDPOINT is missing.
        Example: <account-id>.r2.cloudflarestorage.com
        """),
    # Optional: Custom domain if configured in R2
    public_url: System.get_env("R2_PUBLIC_URL"),
    # Upload security limits
    # 5MB
    max_file_size: 5 * 1024 * 1024,
    max_image_width: 2048,
    max_image_height: 2048
end

# POP3 Server configuration
# Always use port 2110 (non-privileged port) to avoid permission issues.
# Keep test isolated from host mail daemons by letting test.exs own these ports.
if config_env() != :test do
  config :elektrine,
    pop3_enabled: true,
    pop3_port: 2110
end

# Server network metadata
config :elektrine, server_public_ip: System.get_env("SERVER_PUBLIC_IP")

if acme_contact_email = System.get_env("ACME_CONTACT_EMAIL") do
  config :elektrine, :acme_contact_email, acme_contact_email
end

# ACME (Let's Encrypt) environment
# Use :staging for testing (fake certs), :production for real certificates
if System.get_env("ACME_ENVIRONMENT") == "production" do
  config :elektrine, :acme_environment, :production
end

# Stripe configuration for subscriptions
if System.get_env("STRIPE_SECRET_KEY") do
  config :stripity_stripe,
    api_key: System.get_env("STRIPE_SECRET_KEY"),
    signing_secret: System.get_env("STRIPE_WEBHOOK_SECRET")
end
