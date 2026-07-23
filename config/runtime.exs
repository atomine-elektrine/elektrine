import Config

alias Elektrine.Platform.Modules
alias Elektrine.RuntimeSecrets

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

runtime_env = System.get_env()

iftas_blocklist_enabled =
  case System.get_env("IFTAS_BLOCKLIST_ENABLED", "true") do
    value when value in ["1", "true", "TRUE", "yes", "YES"] -> true
    _ -> false
  end

iftas_blocklist_threshold =
  case Integer.parse(System.get_env("IFTAS_BLOCKLIST_THRESHOLD", "66")) do
    {threshold, ""} when threshold in [51, 66, 80] -> threshold
    _ -> 66
  end

iftas_blocklist_url =
  case System.get_env("IFTAS_BLOCKLIST_URL") do
    nil -> nil
    "" -> nil
    value -> value
  end

iftas_blocklist_api_key =
  case System.get_env("IFTAS_BLOCKLIST_API_KEY") do
    nil -> nil
    "" -> nil
    value -> value
  end

config :elektrine_social, :iftas_blocklist,
  enabled: iftas_blocklist_enabled,
  threshold: iftas_blocklist_threshold,
  url: iftas_blocklist_url,
  api_key: iftas_blocklist_api_key

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

parse_bool_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      default

    value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] ->
      true

    value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] ->
      false

    _ ->
      default
  end
end

analytics_retention_config = Application.get_env(:elektrine, :analytics_retention, [])

config :elektrine, :analytics_retention,
  site_retention_days:
    parse_int_env.(
      "ANALYTICS_SITE_RETENTION_DAYS",
      Keyword.get(analytics_retention_config, :site_retention_days, 30)
    ),
  profile_retention_days:
    parse_int_env.(
      "ANALYTICS_PROFILE_RETENTION_DAYS",
      Keyword.get(analytics_retention_config, :profile_retention_days, 90)
    ),
  batch_size:
    parse_int_env.(
      "ANALYTICS_RETENTION_BATCH_SIZE",
      Keyword.get(analytics_retention_config, :batch_size, 5_000)
    ),
  max_batches:
    parse_int_env.(
      "ANALYTICS_RETENTION_MAX_BATCHES",
      Keyword.get(analytics_retention_config, :max_batches, 100)
    )

parse_logger_level_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      default

    value when value in ["crash_only", "crashes", "none", "nil"] ->
      nil

    value ->
      normalized = value |> String.trim() |> String.downcase()

      case normalized do
        "debug" -> :debug
        "info" -> :info
        "notice" -> :notice
        "warning" -> :warning
        "warn" -> :warning
        "error" -> :error
        "critical" -> :critical
        "alert" -> :alert
        "emergency" -> :emergency
        _ -> default
      end
  end
end

present_env = fn names ->
  Enum.find_value(List.wrap(names), fn env_name ->
    case System.get_env(env_name) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end)
end

# Keep Oban concurrency proportional to the DB pool available to the role
# that actually executes jobs. Web-only nodes run enqueue-only Oban.
oban_db_pool_size = parse_int_env.("POOL_SIZE", 10)

oban_queue_override = fn env_name, default ->
  parse_int_env.(env_name, default)
end

config :atomine, :credits,
  dm_gate_enabled: parse_bool_env.("ATOMINE_DM_CREDIT_GATE_ENABLED", false),
  email_gate_enabled: parse_bool_env.("ATOMINE_EMAIL_CREDIT_GATE_ENABLED", true)

config :elektrine, :atomine_pow,
  difficulty:
    parse_int_env.(
      "ATOMINE_POW_DIFFICULTY",
      Application.get_env(:elektrine, :atomine_pow, []) |> Keyword.get(:difficulty, 20)
    ),
  skip_verification:
    parse_bool_env.(
      "ATOMINE_POW_SKIP_VERIFICATION",
      Application.get_env(:elektrine, :atomine_pow, []) |> Keyword.get(:skip_verification, false)
    )

config :elektrine, :atomine_gate,
  enabled:
    parse_bool_env.(
      "ATOMINE_GATE_ENABLED",
      Application.get_env(:elektrine, :atomine_gate, []) |> Keyword.get(:enabled, false)
    ),
  difficulty:
    parse_int_env.(
      "ATOMINE_GATE_DIFFICULTY",
      Application.get_env(:elektrine, :atomine_gate, []) |> Keyword.get(:difficulty, 20)
    ),
  clearance_ttl_seconds:
    parse_int_env.(
      "ATOMINE_GATE_CLEARANCE_TTL_SECONDS",
      Application.get_env(:elektrine, :atomine_gate, [])
      |> Keyword.get(:clearance_ttl_seconds, 12 * 60 * 60)
    )

paige_brave_api_key =
  present_env.(["PAIGE_BRAVE_API_KEY", "BRAVE_SEARCH_API_KEY", "BRAVE_API_KEY"])

paige_github_token = present_env.(["PAIGE_GITHUB_TOKEN"])

paige_index_enabled = config_env() != :test and parse_bool_env.("PAIGE_INDEX_ENABLED", true)

paige_index_seeds =
  System.get_env("PAIGE_INDEX_SEEDS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.uniq()

config :elektrine, :web_index,
  enabled: paige_index_enabled,
  seeds: paige_index_seeds,
  max_depth: parse_int_env.("PAIGE_INDEX_MAX_DEPTH", 2),
  recrawl_seconds: parse_int_env.("PAIGE_INDEX_RECRAWL_SECONDS", 7 * 24 * 60 * 60),
  schedule_batch_size: parse_int_env.("PAIGE_INDEX_BATCH_SIZE", 100)

paige_scraper_names =
  if config_env() == :test do
    []
  else
    System.get_env("PAIGE_SCRAPERS", "wiby")
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.uniq()
  end

paige_scraper_providers =
  Enum.flat_map(paige_scraper_names, fn
    "wiby" ->
      [
        {Paige.Providers.Wiby,
         [
           kinds: [:web],
           scoring: :rank,
           score_offset: -3,
           max_results: 12,
           page_size: 12,
           paginated: true
         ]}
      ]

    "duckduckgo" ->
      [
        {Paige.Providers.DuckDuckGo,
         [
           kinds: [:web],
           scoring: :rank,
           score_offset: -2,
           max_results: 20,
           page_size: 20,
           paginated: true
         ]}
      ]

    _unknown ->
      []
  end)

# Supplementary sources blend a handful of results into web searches below the
# top Brave hits. They are rank-scored so native scores (stars, points, page
# sizes) can't dominate the blend. GitHub search is heavily rate-limited
# without a token, so it stays off unless one is configured.
paige_web_blend = fn extra ->
  Keyword.merge([kinds: [:web], scoring: :rank, max_results: 3, paginated: true], extra)
end

paige_supplementary_providers =
  if config_env() == :test do
    []
  else
    [
      {Paige.Providers.Wikipedia, paige_web_blend.(score_offset: -5, max_results: 2)},
      {Paige.Providers.HackerNews, paige_web_blend.(score_offset: -7)},
      paige_github_token &&
        {Paige.Providers.GitHub, paige_web_blend.(score_offset: -8, token: paige_github_token)}
    ]
  end

paige_providers =
  [
    paige_index_enabled &&
      {Elektrine.WebIndex.Provider,
       [
         kinds: [:web],
         scoring: :rank,
         score_offset: 2,
         max_results: 10,
         page_size: 10,
         paginated: true
       ]},
    paige_brave_api_key &&
      {Paige.Providers.Brave,
       [api_key: paige_brave_api_key, paginated_kinds: [:web, :videos, :news]]}
  ]
  |> Enum.concat(paige_scraper_providers)
  |> Enum.concat(paige_supplementary_providers)
  |> Enum.filter(& &1)

config :paige,
  providers: paige_providers,
  brave_api_key: paige_brave_api_key

oban_queues =
  cond do
    oban_db_pool_size <= 5 ->
      [
        default: oban_queue_override.("OBAN_QUEUE_DEFAULT", 1),
        activitypub: oban_queue_override.("OBAN_QUEUE_ACTIVITYPUB", 1),
        activitypub_delivery: oban_queue_override.("OBAN_QUEUE_ACTIVITYPUB_DELIVERY", 1),
        email: oban_queue_override.("OBAN_QUEUE_EMAIL", 1),
        email_inbound: oban_queue_override.("OBAN_QUEUE_EMAIL_INBOUND", 1),
        rss: oban_queue_override.("OBAN_QUEUE_RSS", 1),
        exports: oban_queue_override.("OBAN_QUEUE_EXPORTS", 1),
        webhooks: oban_queue_override.("OBAN_QUEUE_WEBHOOKS", 1),
        federation_metadata: oban_queue_override.("OBAN_QUEUE_FEDERATION_METADATA", 1),
        federation: oban_queue_override.("OBAN_QUEUE_FEDERATION", 1),
        messaging_federation: oban_queue_override.("OBAN_QUEUE_MESSAGING_FEDERATION", 1),
        uptime: oban_queue_override.("OBAN_QUEUE_UPTIME", 1),
        kairo: oban_queue_override.("OBAN_QUEUE_KAIRO", 1),
        crawler: oban_queue_override.("OBAN_QUEUE_CRAWLER", 1)
      ]

    oban_db_pool_size <= 10 ->
      [
        default: oban_queue_override.("OBAN_QUEUE_DEFAULT", 2),
        activitypub: oban_queue_override.("OBAN_QUEUE_ACTIVITYPUB", 2),
        activitypub_delivery: oban_queue_override.("OBAN_QUEUE_ACTIVITYPUB_DELIVERY", 1),
        email: oban_queue_override.("OBAN_QUEUE_EMAIL", 1),
        email_inbound: oban_queue_override.("OBAN_QUEUE_EMAIL_INBOUND", 1),
        rss: oban_queue_override.("OBAN_QUEUE_RSS", 1),
        exports: oban_queue_override.("OBAN_QUEUE_EXPORTS", 1),
        webhooks: oban_queue_override.("OBAN_QUEUE_WEBHOOKS", 1),
        federation_metadata: oban_queue_override.("OBAN_QUEUE_FEDERATION_METADATA", 1),
        federation: oban_queue_override.("OBAN_QUEUE_FEDERATION", 2),
        messaging_federation: oban_queue_override.("OBAN_QUEUE_MESSAGING_FEDERATION", 2),
        uptime: oban_queue_override.("OBAN_QUEUE_UPTIME", 2),
        kairo: oban_queue_override.("OBAN_QUEUE_KAIRO", 1),
        crawler: oban_queue_override.("OBAN_QUEUE_CRAWLER", 1)
      ]

    true ->
      [
        default: oban_queue_override.("OBAN_QUEUE_DEFAULT", 3),
        activitypub: oban_queue_override.("OBAN_QUEUE_ACTIVITYPUB", 3),
        activitypub_delivery: oban_queue_override.("OBAN_QUEUE_ACTIVITYPUB_DELIVERY", 2),
        email: oban_queue_override.("OBAN_QUEUE_EMAIL", 2),
        email_inbound: oban_queue_override.("OBAN_QUEUE_EMAIL_INBOUND", 2),
        rss: oban_queue_override.("OBAN_QUEUE_RSS", 2),
        exports: oban_queue_override.("OBAN_QUEUE_EXPORTS", 2),
        webhooks: oban_queue_override.("OBAN_QUEUE_WEBHOOKS", 2),
        federation_metadata: oban_queue_override.("OBAN_QUEUE_FEDERATION_METADATA", 2),
        federation: oban_queue_override.("OBAN_QUEUE_FEDERATION", 2),
        messaging_federation: oban_queue_override.("OBAN_QUEUE_MESSAGING_FEDERATION", 4),
        uptime: oban_queue_override.("OBAN_QUEUE_UPTIME", 4),
        kairo: oban_queue_override.("OBAN_QUEUE_KAIRO", 2),
        crawler: oban_queue_override.("OBAN_QUEUE_CRAWLER", 2)
      ]
  end

config :elektrine, Oban, queues: oban_queues

# Drop cron entries whose worker module isn't bundled in this release build.
# Module-specific workers (uptime, email, social, ...) are only present when
# their platform module is compiled in. Oban validates the whole crontab on
# boot, so a single missing worker would crash the app - fatal for partial
# builds (e.g. ELEKTRINE_RELEASE_MODULES=chat). Filtering by module
# loadability keeps the scheduler running with whatever modules are present.
oban_existing_plugins = Application.get_env(:elektrine, Oban, []) |> Keyword.get(:plugins)

if is_list(oban_existing_plugins) do
  filtered_oban_plugins =
    Enum.map(oban_existing_plugins, fn
      {Oban.Plugins.Cron, cron_opts} ->
        crontab =
          cron_opts
          |> Keyword.get(:crontab, [])
          |> Enum.filter(fn entry -> Code.ensure_loaded?(elem(entry, 1)) end)

        {Oban.Plugins.Cron, Keyword.put(cron_opts, :crontab, crontab)}

      other ->
        other
    end)

  config :elektrine, Oban, plugins: filtered_oban_plugins
end

first_present_env = fn env_names ->
  Enum.find_value(env_names, fn env_name ->
    case System.get_env(env_name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end)
end

config :elektrine, :runtime_components,
  web: parse_bool_env.("ELEKTRINE_ENABLE_WEB", true),
  jobs: parse_bool_env.("ELEKTRINE_ENABLE_JOBS", true),
  mail: parse_bool_env.("ELEKTRINE_ENABLE_MAIL", true)

enabled_platform_modules =
  case System.get_env("ELEKTRINE_ENABLED_MODULES") do
    nil ->
      Application.get_env(:elektrine, :platform_modules, [])
      |> Keyword.get(:enabled, Modules.default_enabled())

    value ->
      value
  end
  |> Modules.normalize_enabled_modules()

config :elektrine, :platform_modules, enabled: enabled_platform_modules

Code.eval_file(Path.expand("runtime/bluesky.exs", __DIR__))

# Default OFF for local-first timeline performance.
timeline_remote_enrichment_enabled =
  case System.get_env("TIMELINE_REMOTE_ENRICHMENT", "false") do
    value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] -> false
    _ -> true
  end

config :elektrine, :timeline_remote_enrichment, timeline_remote_enrichment_enabled

recommendations_enabled =
  case System.get_env("RECOMMENDATIONS_ENABLED", "true") do
    value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] -> false
    _ -> true
  end

config :elektrine, :recommendations_enabled, recommendations_enabled

haraka_async_ingest_enabled =
  case System.get_env("HARAKA_ASYNC_INGEST", "true") do
    value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
    _ -> false
  end

config :elektrine, :haraka_async_ingest, haraka_async_ingest_enabled

email_auto_suppression_enabled =
  case System.get_env("EMAIL_AUTO_SUPPRESSION", "true") do
    value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
    _ -> false
  end

config :elektrine, :email_auto_suppression, email_auto_suppression_enabled

# Native push notifications (APNs/FCM) and browser Web Push (VAPID).
# Generate VAPID keys with: Elektrine.Push.WebPushClient.generate_vapid_keys/0
config :elektrine, :push,
  enabled: parse_bool_env.("PUSH_ENABLED", false),
  apns_topic: System.get_env("PUSH_APNS_TOPIC") || "com.elektrine.app",
  web_push_public_key: System.get_env("WEB_PUSH_PUBLIC_KEY"),
  web_push_private_key: System.get_env("WEB_PUSH_PRIVATE_KEY"),
  web_push_subject: System.get_env("WEB_PUSH_SUBJECT")

# Configure the Haraka mail adapter whenever the email module is enabled.
runtime_primary_domain =
  System.get_env("PRIMARY_DOMAIN") ||
    Application.get_env(:elektrine, :primary_domain, "example.com")

runtime_email_domain =
  System.get_env("EMAIL_DOMAIN") ||
    Application.get_env(:elektrine, :email, []) |> Keyword.get(:domain, runtime_primary_domain)

derived_internal_api_key = RuntimeSecrets.internal_api_key(runtime_env)
derived_haraka_signing_secret = RuntimeSecrets.haraka_internal_signing_secret(runtime_env)
derived_receiver_webhook_secret = RuntimeSecrets.email_receiver_webhook_secret(runtime_env)

Code.eval_file(Path.expand("runtime/webrtc.exs", __DIR__))

config :elektrine,
  internal_api_key: derived_internal_api_key,
  session_signing_salt: RuntimeSecrets.session_signing_salt(runtime_env),
  session_encryption_salt: RuntimeSecrets.session_encryption_salt(runtime_env)

if config_env() != :test and :email in enabled_platform_modules do
  config :elektrine, Elektrine.Mailer,
    adapter: Elektrine.Email.HarakaAdapter,
    api_key:
      first_present_env.([
        "HARAKA_HTTP_API_KEY",
        "HARAKA_OUTBOUND_API_KEY",
        "HARAKA_API_KEY"
      ]) || derived_internal_api_key,
    base_url: first_present_env.(["HARAKA_BASE_URL"]) || "https://mail.#{runtime_email_domain}",
    timeout: 30_000

  # Enable API client for Haraka
  config :swoosh, :api_client, Swoosh.ApiClient.Finch
end

# Configure encryption.
# In production, missing encryption secrets fail validation unless unencrypted data
# has been explicitly allowed with ELEKTRINE_ALLOW_UNENCRYPTED_PROD_DATA=true.
encryption_master_secret = RuntimeSecrets.encryption_master_secret(runtime_env)
encryption_key_salt = RuntimeSecrets.encryption_key_salt(runtime_env)
encryption_search_salt = RuntimeSecrets.encryption_search_salt(runtime_env)

non_prod_encryption_master_secret =
  :crypto.hash(:sha256, "elektrine:nonprod:encryption_master_secret")
  |> Base.encode64()

non_prod_encryption_key_salt =
  :crypto.hash(:sha256, "elektrine:nonprod:encryption_key_salt")
  |> binary_part(0, 16)
  |> Base.encode64()

non_prod_encryption_search_salt =
  :crypto.hash(:sha256, "elektrine:nonprod:encryption_search_salt")
  |> binary_part(0, 16)
  |> Base.encode64()

encryption_configured =
  Enum.all?(
    [encryption_master_secret, encryption_key_salt, encryption_search_salt],
    &(is_binary(&1) and String.trim(&1) != "")
  )

allow_unencrypted_prod_data =
  config_env() == :prod and
    parse_bool_env.("ELEKTRINE_ALLOW_UNENCRYPTED_PROD_DATA", false) and
    not encryption_configured

if config_env() == :prod do
  config :elektrine,
    encryption_enabled: encryption_configured and not allow_unencrypted_prod_data,
    encryption_master_secret: encryption_master_secret,
    encryption_key_salt: encryption_key_salt,
    encryption_search_salt: encryption_search_salt
else
  # Keep encryption on by default outside prod, but use stable fallback secrets so
  # separate BEAM processes (for example a running dev server plus `mix run` seeds)
  # can still decrypt each other's rows.
  config :elektrine,
    encryption_enabled: true,
    encryption_master_secret: encryption_master_secret || non_prod_encryption_master_secret,
    encryption_key_salt: encryption_key_salt || non_prod_encryption_key_salt,
    encryption_search_salt: encryption_search_salt || non_prod_encryption_search_salt
end

if config_env() == :prod do
  config :elektrine, :environment, :prod
  config :elektrine, :enforce_https, parse_bool_env.("FORCE_SSL", true)
  config :elektrine, :allow_insecure_dav_jmap_auth, false
  config :elektrine, :allow_insecure_mail_auth, false

  Elektrine.Platform.RuntimeConfigValidator.validate!(
    env: System.get_env(),
    environment: :prod,
    compiled_modules: Application.get_env(:elektrine, :compiled_platform_modules, []),
    enabled_modules: enabled_platform_modules
  )

  trusted_proxy_cidrs =
    System.get_env("TRUSTED_PROXY_CIDRS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  config :elektrine, :trusted_proxy_cidrs, trusted_proxy_cidrs

  proxy_protocol_trusted_cidrs =
    System.get_env("PROXY_PROTOCOL_TRUSTED_CIDRS", System.get_env("TRUSTED_PROXY_CIDRS", ""))
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  config :elektrine, :proxy_protocol_trusted_cidrs, proxy_protocol_trusted_cidrs

  netbird_allowed_cidrs =
    System.get_env("NETBIRD_ALLOWED_CIDRS", "")
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&String.trim/1)

  config :elektrine, :netbird,
    enabled: parse_bool_env.("NETBIRD_ENABLED", false),
    allowed_cidrs: netbird_allowed_cidrs

  # Production paths - use persistent /data volume
  config :elektrine, :export_dir, "/data/exports"

  posthog_api_key = System.get_env("POSTHOG_API_KEY")
  posthog_enabled = is_binary(posthog_api_key) and String.trim(posthog_api_key) != ""

  config :posthog,
    enable: posthog_enabled,
    enable_error_tracking: posthog_enabled,
    api_key: posthog_api_key,
    api_host: System.get_env("POSTHOG_HOST", "https://us.i.posthog.com"),
    in_app_otp_apps: [
      :elektrine,
      :elektrine_web,
      :elektrine_email,
      :arblarg,
      :elektrine_dns,
      :elektrine_social,
      :elektrine_vpn
    ],
    # Plain Logger.error/1 events do not include stacktraces. Capture crashes by
    # default, and opt back into log-level capture with POSTHOG_CAPTURE_LEVEL.
    capture_level: parse_logger_level_env.("POSTHOG_CAPTURE_LEVEL", nil),
    metadata: [:request_id, :user_id],
    global_properties: %{environment: :prod},
    enable_source_code_context: posthog_enabled,
    context_lines: 5

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
      nil -> false
      value -> value in ~w(true 1)
    end

  maybe_ipv6 = if ecto_ipv6, do: [:inet6], else: []

  db_ssl_server_name =
    case System.get_env("DATABASE_SSL_SERVER_NAME") do
      nil -> database_uri.host
      "" -> database_uri.host
      hostname -> hostname
    end

  db_ssl_enabled = parse_bool_env.("DATABASE_SSL_ENABLED", true)

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
    if db_ssl_enabled do
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
    else
      false
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

  pool_size = env_int.("POOL_SIZE", 10)
  queue_target_ms = env_int.("DB_QUEUE_TARGET_MS", 2_000)
  queue_interval_ms = env_int.("DB_QUEUE_INTERVAL_MS", 5_000)
  query_timeout_ms = env_int.("DB_TIMEOUT_MS", 30_000)
  pool_timeout_ms = env_int.("DB_POOL_TIMEOUT_MS", 15_000)
  connect_timeout_ms = env_int.("DB_CONNECT_TIMEOUT_MS", 15_000)
  ap_inbox_max_per_ip_per_minute = env_int.("AP_INBOX_MAX_PER_IP_PER_MINUTE", 10)
  ap_inbox_max_per_domain_per_minute = env_int.("AP_INBOX_MAX_PER_DOMAIN_PER_MINUTE", 20)
  ap_inbox_max_global_per_second = env_int.("AP_INBOX_MAX_GLOBAL_PER_SECOND", 4)

  # SSL configuration for PostgreSQL.
  # Defaults to certificate verification (DATABASE_SSL_VERIFY=peer).
  # To disable verification for private-network deployments, set DATABASE_SSL_VERIFY=none.
  # To disable TLS entirely for internal-only databases, set DATABASE_SSL_ENABLED=false.
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
    RuntimeSecrets.secret_key_base(runtime_env) ||
      raise """
      one of SECRET_KEY_BASE or ELEKTRINE_MASTER_SECRET must be set.
      ELEKTRINE_MASTER_SECRET is required when deriving internal runtime secrets.
      """

  session_signing_salt =
    RuntimeSecrets.session_signing_salt(runtime_env) ||
      raise """
      one of SESSION_SIGNING_SALT or ELEKTRINE_MASTER_SECRET must be set.
      ELEKTRINE_MASTER_SECRET is required when deriving internal runtime secrets.
      """

  RuntimeSecrets.session_encryption_salt(runtime_env) ||
    raise """
    one of SESSION_ENCRYPTION_SALT or ELEKTRINE_MASTER_SECRET must be set.
    Without a session encryption salt the session cookie would be signed but
    not encrypted in production.
    """

  normalize_domain = fn domain ->
    domain
    |> String.trim()
    |> String.downcase()
    |> String.trim_leading("www.")
  end

  parse_domain_list = fn value, default ->
    domains =
      case value do
        nil -> default
        "" -> default
        raw -> String.split(raw, ",", trim: true)
      end

    domains
    |> Enum.map(normalize_domain)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  parse_origin_list = fn value ->
    case value do
      nil ->
        []

      "" ->
        []

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
    end
  end

  primary_domain_env = System.get_env("PRIMARY_DOMAIN")

  primary_domain =
    case primary_domain_env do
      nil ->
        raise """
        environment variable PRIMARY_DOMAIN is missing.
        Set PRIMARY_DOMAIN to the main public domain for this instance, for example: example.com
        """

      value ->
        normalize_domain.(value)
    end

  email_domain =
    case System.get_env("EMAIL_DOMAIN") do
      nil -> primary_domain
      "" -> primary_domain
      value -> normalize_domain.(value)
    end

  official_elektrine_domains = [
    "elektrine.com",
    "elektrine.net",
    "elektrine.org",
    "maidcorps.net"
  ]

  default_supported_domains =
    if primary_domain in official_elektrine_domains or email_domain in official_elektrine_domains do
      official_elektrine_domains
    else
      [email_domain]
    end

  supported_domains_env =
    System.get_env("SUPPORTED_DOMAINS") || System.get_env("EMAIL_SUPPORTED_DOMAINS")

  configured_supported_domains =
    parse_domain_list.(supported_domains_env, default_supported_domains)

  receive_only_email_domains =
    configured_supported_domains
    |> Enum.reject(&(&1 in [primary_domain, email_domain] or &1 in official_elektrine_domains))
    |> Enum.uniq()

  supported_email_domains =
    ([primary_domain] ++ configured_supported_domains)
    |> Enum.reject(&(&1 in receive_only_email_domains))
    |> Enum.uniq()

  profile_domains_env = System.get_env("PROFILE_BASE_DOMAINS")

  profile_base_domains =
    parse_domain_list.(profile_domains_env, [primary_domain])
    |> Enum.reject(&(&1 in receive_only_email_domains))

  public_base_url_env =
    first_present_env.(["PUBLIC_BASE_URL", "APP_BASE_URL", "PHX_PUBLIC_URL", "NGROK_URL"])

  public_base_uri =
    case public_base_url_env do
      value when is_binary(value) and value != "" -> URI.parse(String.trim(value))
      _ -> nil
    end

  host =
    (public_base_uri && public_base_uri.host) ||
      System.get_env("PHX_HOST") ||
      primary_domain

  public_scheme =
    case public_base_uri do
      %URI{scheme: scheme} when is_binary(scheme) and scheme != "" -> scheme
      _ -> "https"
    end

  public_port =
    case public_base_uri do
      %URI{port: port} when is_integer(port) -> port
      _ -> 443
    end

  host_domain = normalize_domain.(host)

  admin_host_domain =
    case System.get_env("CADDY_ADMIN_HOST") do
      value when is_binary(value) and value != "" -> normalize_domain.(value)
      _ -> nil
    end

  all_public_domains =
    ([host_domain, admin_host_domain] ++ supported_email_domains ++ profile_base_domains)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()

  custom_domain_mx_host =
    case System.get_env("CUSTOM_DOMAIN_MX_HOST") do
      nil -> normalize_domain.("mail.#{email_domain}")
      "" -> normalize_domain.("mail.#{email_domain}")
      value -> normalize_domain.(value)
    end

  custom_domain_mx_priority = parse_int_env.("CUSTOM_DOMAIN_MX_PRIORITY", 10)

  custom_domain_spf_include =
    case System.get_env("CUSTOM_DOMAIN_SPF_INCLUDE") do
      nil -> nil
      "" -> nil
      value -> normalize_domain.(value)
    end

  custom_domain_dkim_selector =
    case System.get_env("CUSTOM_DOMAIN_DKIM_SELECTOR") do
      nil -> "default"
      "" -> "default"
      value -> value
    end

  custom_domain_dkim_sync_enabled = parse_bool_env.("CUSTOM_DOMAIN_DKIM_SYNC_ENABLED", true)

  custom_domain_haraka_base_url =
    case first_present_env.(["CUSTOM_DOMAIN_HARAKA_BASE_URL", "HARAKA_BASE_URL"]) do
      nil -> "https://mail.#{email_domain}"
      value -> String.trim_trailing(value, "/")
    end

  custom_domain_haraka_api_key =
    case first_present_env.([
           "CUSTOM_DOMAIN_HARAKA_API_KEY",
           "HARAKA_HTTP_API_KEY",
           "HARAKA_OUTBOUND_API_KEY",
           "HARAKA_API_KEY"
         ]) do
      nil -> derived_internal_api_key
      value -> value
    end

  custom_domain_haraka_timeout = parse_int_env.("CUSTOM_DOMAIN_HARAKA_TIMEOUT_MS", 10_000)

  max_retained_raw_source_bytes =
    parse_int_env.("EMAIL_RAW_SOURCE_MAX_BYTES", 10 * 1024 * 1024)

  custom_domain_haraka_dkim_path =
    case System.get_env("CUSTOM_DOMAIN_HARAKA_DKIM_PATH") do
      nil -> "/api/v1/dkim/domains"
      "" -> "/api/v1/dkim/domains"
      value -> value
    end

  custom_domain_dmarc_policy =
    case System.get_env("CUSTOM_DOMAIN_DMARC_POLICY") do
      nil -> "quarantine"
      "" -> "quarantine"
      value -> String.downcase(value)
    end

  custom_domain_dmarc_rua =
    case System.get_env("CUSTOM_DOMAIN_DMARC_RUA") do
      nil -> nil
      "" -> nil
      value -> value
    end

  custom_domain_dmarc_adkim =
    case System.get_env("CUSTOM_DOMAIN_DMARC_ADKIM") do
      nil -> "s"
      "" -> "s"
      value -> String.downcase(value)
    end

  custom_domain_dmarc_aspf =
    case System.get_env("CUSTOM_DOMAIN_DMARC_ASPF") do
      nil -> "s"
      "" -> "s"
      value -> String.downcase(value)
    end

  config :elektrine, :email,
    domain: email_domain,
    max_retained_raw_source_bytes: max_retained_raw_source_bytes,
    allow_insecure_receiver_webhook: false,
    receiver_webhook_secret: derived_receiver_webhook_secret,
    internal_signing_secret: derived_haraka_signing_secret,
    supported_domains: supported_email_domains,
    receive_only_domains: receive_only_email_domains,
    custom_domain_mx_host: custom_domain_mx_host,
    custom_domain_mx_priority: custom_domain_mx_priority,
    custom_domain_spf_include: custom_domain_spf_include,
    custom_domain_dkim_selector: custom_domain_dkim_selector,
    custom_domain_dkim_sync_enabled: custom_domain_dkim_sync_enabled,
    custom_domain_haraka_base_url: custom_domain_haraka_base_url,
    custom_domain_haraka_api_key: custom_domain_haraka_api_key,
    custom_domain_haraka_timeout: custom_domain_haraka_timeout,
    custom_domain_haraka_dkim_path: custom_domain_haraka_dkim_path,
    custom_domain_dmarc_policy: custom_domain_dmarc_policy,
    custom_domain_dmarc_rua: custom_domain_dmarc_rua,
    custom_domain_dmarc_adkim: custom_domain_dmarc_adkim,
    custom_domain_dmarc_aspf: custom_domain_dmarc_aspf

  config :elektrine, :profile_base_domains, profile_base_domains
  config :elektrine, :primary_domain, primary_domain

  port = String.to_integer(System.get_env("PORT") || "4000")
  http_ip_env = System.get_env("PHX_HTTP_IP") || "0.0.0.0"

  http_ip =
    case :inet.parse_address(String.to_charlist(String.trim(http_ip_env))) do
      {:ok, ip} -> ip
      _ -> {0, 0, 0, 0}
    end

  onion_tls_port = String.to_integer(System.get_env("ONION_TLS_PORT") || "8443")
  onion_tls_certfile = System.get_env("ONION_TLS_CERTFILE") || "/data/certs/live/onion-cert.pem"
  onion_tls_keyfile = System.get_env("ONION_TLS_KEYFILE") || "/data/certs/live/onion-key.pem"

  onion_tls_enabled =
    case System.get_env("ONION_TLS_ENABLED", "true") do
      value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
      _ -> false
    end

  config :elektrine, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  endpoint_http = [
    ip: http_ip,
    port: port,
    http_1_options: [
      max_header_count: 50,
      max_header_length: 32_768
    ]
  ]

  onion_https =
    if onion_tls_enabled and File.regular?(onion_tls_certfile) and
         File.regular?(onion_tls_keyfile) do
      [
        ip: {0, 0, 0, 0},
        port: onion_tls_port,
        cipher_suite: :strong,
        certfile: onion_tls_certfile,
        keyfile: onion_tls_keyfile,
        http_1_options: [
          max_header_count: 50,
          max_header_length: 32_768
        ]
      ]
    else
      nil
    end

  # The Tor onion mirror is reached over http:// (and https:// when ONION_TLS is
  # on). Its origin must be allow-listed for the LiveView WebSocket; without it
  # the socket handshake is rejected and the client falls back to longpoll. We
  # only trust the operator's own ONION_HOST, never every .onion, so a hostile
  # onion site can't hijack the socket (CSWSH).
  onion_origins =
    case System.get_env("ONION_HOST") do
      value when is_binary(value) and value != "" ->
        host = normalize_domain.(value)
        ["http://#{host}", "https://#{host}"]

      _ ->
        []
    end

  # Allowed origins for WebSocket connections. Keep defaults to exact app hosts;
  # add any required profile/onion/custom origins through EXTRA_CHECK_ORIGINS.
  allowed_origins =
    all_public_domains
    |> Enum.flat_map(fn domain ->
      [
        "https://#{domain}",
        "https://www.#{domain}"
      ]
    end)
    |> Kernel.++(onion_origins)
    |> Kernel.++(parse_origin_list.(System.get_env("EXTRA_CHECK_ORIGINS")))
    |> Enum.uniq()

  endpoint_config = [
    url: [host: host, port: public_port, scheme: public_scheme],
    http: endpoint_http,
    secret_key_base: secret_key_base,
    live_view: [signing_salt: session_signing_salt],
    check_origin: allowed_origins
  ]

  endpoint_config =
    if onion_https do
      Keyword.put(endpoint_config, :https, onion_https)
    else
      endpoint_config
    end

  # Clearnet traffic usually terminates TLS at the reverse proxy.
  # Onion traffic can terminate TLS in-app on :https when cert/key files are present.
  config :elektrine, ElektrineWeb.Endpoint, endpoint_config

  # WebAuthn/Passkey configuration for production
  # Uses the PHX_HOST environment variable for RP ID
  config :elektrine,
    passkey_rp_id: host,
    passkey_origin: "https://#{host}"

  config :elektrine, :admin_security,
    require_passkey: parse_bool_env.("ADMIN_REQUIRE_PASSKEY", true),
    access_ttl_seconds: parse_int_env.("ADMIN_ACCESS_TTL_SECONDS", 15 * 60),
    elevation_ttl_seconds: parse_int_env.("ADMIN_ELEVATION_TTL_SECONDS", 5 * 60),
    action_grant_ttl_seconds: parse_int_env.("ADMIN_ACTION_GRANT_TTL_SECONDS", 90),
    intent_ttl_seconds: parse_int_env.("ADMIN_INTENT_TTL_SECONDS", 3 * 60),
    replay_ttl_seconds: parse_int_env.("ADMIN_ACTION_REPLAY_TTL_SECONDS", 10 * 60)

  config :elektrine, :atomine_pow,
    difficulty: parse_int_env.("ATOMINE_POW_DIFFICULTY", 20),
    skip_verification: parse_bool_env.("ATOMINE_POW_SKIP_VERIFICATION", false)

  config :elektrine, :atomine_gate,
    enabled: parse_bool_env.("ATOMINE_GATE_ENABLED", false),
    difficulty: parse_int_env.("ATOMINE_GATE_DIFFICULTY", 20),
    clearance_ttl_seconds: parse_int_env.("ATOMINE_GATE_CLEARANCE_TTL_SECONDS", 12 * 60 * 60)

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
  # `:compatible` TLS mode for broader client support.
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

  Code.eval_file(Path.expand("runtime/uploads.exs", __DIR__))
end

Code.eval_file(Path.expand("runtime/mail_protocols.exs", __DIR__))
Code.eval_file(Path.expand("runtime/dns.exs", __DIR__))
Code.eval_file(Path.expand("runtime/messaging_federation.exs", __DIR__))
Code.eval_file(Path.expand("runtime/stripe.exs", __DIR__))
