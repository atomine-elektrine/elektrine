import Config

# Multiple umbrella apps intentionally share common test helper module names
# (e.g. Elektrine.DataCase, fixture modules). Ignore redefinition warnings in test.
config :elixir, :compiler_options, ignore_module_conflict: true

config :elektrine,
  enforce_https: false,
  allow_insecure_dav_jmap_auth: true,
  trusted_proxy_cidrs: ["127.0.0.1/32", "::1/128"]

ci_env? = System.get_env("CI") in ["true", "1"]

test_db_username =
  System.get_env("DB_USER") ||
    System.get_env("POSTGRES_USER") ||
    System.get_env("PGUSER") ||
    if(ci_env?, do: "postgres", else: System.get_env("USER") || "postgres")

test_db_password =
  System.get_env("DB_PASSWORD") ||
    System.get_env("POSTGRES_PASSWORD") ||
    System.get_env("PGPASSWORD") ||
    if(ci_env?, do: "postgres", else: "")

test_db_hostname = System.get_env("DB_HOST") || System.get_env("PGHOST") || "localhost"
test_db_name = System.get_env("DB_NAME") || System.get_env("PGDATABASE") || "elektrine_test"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :elektrine, Elektrine.Repo,
  username: test_db_username,
  password: test_db_password,
  hostname: test_db_hostname,
  database: "#{test_db_name}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Isolate mail protocol listeners from any local services on default ports.
config :elektrine,
  imap_port: 32_143,
  pop3_port: 32_110,
  smtp_port: 32_587

# Enable server for Wallaby browser tests
config :elektrine, ElektrineWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  # Generate random secret for tests
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
  server: true

# Wallaby configuration
config :wallaby,
  driver: Wallaby.Chrome,
  screenshot_on_failure: true,
  # Disable JS error checking - LiveView internal errors are not app errors
  js_errors: false,
  chromedriver: [
    headless: true
  ]

# In test we don't send emails
config :elektrine, Elektrine.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Disable Oban in test
config :elektrine, Oban, testing: :inline

# Disable Quantum cron jobs in test.
# Scheduled jobs run in independent processes and can hit Ecto sandbox
# ownership errors when they query the DB during ExUnit.
config :elektrine, Elektrine.Scheduler, jobs: []

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Use local file storage for tests (faster and no external dependencies)
config :elektrine, :uploads,
  adapter: :local,
  uploads_dir: "tmp/test_uploads"

# Skip Turnstile captcha verification in tests
config :elektrine, :turnstile, skip_verification: true

# Set environment for profile access control
config :elektrine, :environment, :test

# Disable async tasks in tests to work with Ecto Sandbox
config :elektrine, :async_enabled, false
