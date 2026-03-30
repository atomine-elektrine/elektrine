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

# Lightweight messaging federation runtime configuration
messaging_federation_enabled =
  case System.get_env("MESSAGING_FEDERATION_ENABLED", "true") do
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

messaging_federation_identity_keys =
  case System.get_env("MESSAGING_FEDERATION_IDENTITY_KEYS_JSON") do
    nil ->
      []

    "" ->
      []

    json ->
      case Jason.decode(json) do
        {:ok, keys} when is_list(keys) -> keys
        _ -> []
      end
  end

messaging_federation_identity_shared_secret =
  case System.get_env("MESSAGING_FEDERATION_IDENTITY_SHARED_SECRET") do
    nil -> nil
    "" -> nil
    value -> value
  end

messaging_federation_official_relay_operator =
  case System.get_env("MESSAGING_FEDERATION_OFFICIAL_RELAY_OPERATOR") do
    nil -> "Community-operated"
    "" -> "Community-operated"
    value -> value
  end

messaging_federation_official_relays =
  case System.get_env("MESSAGING_FEDERATION_OFFICIAL_RELAYS_JSON") do
    nil ->
      []

    "" ->
      []

    json ->
      case Jason.decode(json) do
        {:ok, relays} when is_list(relays) -> relays
        _ -> []
      end
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

parse_dns_endpoint = fn value ->
  trimmed = String.trim(value)

  case Regex.run(~r/^\[(.+)\](?::(\d+))?$/, trimmed) do
    [_, host, port] ->
      with {:ok, ip} <- :inet.parse_address(String.to_charlist(host)),
           {parsed_port, ""} <- Integer.parse(port) do
        {:ok, {ip, parsed_port}}
      else
        _ -> :error
      end

    [_, host] ->
      with {:ok, ip} <- :inet.parse_address(String.to_charlist(host)) do
        {:ok, {ip, 53}}
      else
        _ -> :error
      end

    nil ->
      case String.split(trimmed, ":", parts: 2) do
        [host, port] ->
          with {:ok, ip} <- :inet.parse_address(String.to_charlist(host)),
               {parsed_port, ""} <- Integer.parse(port) do
            {:ok, {ip, parsed_port}}
          else
            _ -> :error
          end

        [host] ->
          with {:ok, ip} <- :inet.parse_address(String.to_charlist(host)) do
            {:ok, {ip, 53}}
          else
            _ -> :error
          end

        _ ->
          :error
      end
  end
end

parse_dns_endpoints = fn value ->
  value
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.map(parse_dns_endpoint)
  |> Enum.flat_map(fn
    {:ok, endpoint} -> [endpoint]
    :error -> []
  end)
  |> Enum.uniq()
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

umami_enabled = parse_bool_env.("UMAMI_ENABLED", true)

umami_script_url =
  case System.get_env("UMAMI_SCRIPT_URL") do
    nil -> "https://cloud.umami.is/script.js"
    "" -> "https://cloud.umami.is/script.js"
    value -> value
  end

umami_website_id =
  case System.get_env("UMAMI_WEBSITE_ID") do
    nil -> nil
    "" -> nil
    value -> value
  end

config :elektrine, :umami,
  enabled: umami_enabled,
  script_url: umami_script_url,
  website_id: umami_website_id

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

dns_nameservers =
  case System.get_env("DNS_NAMESERVERS") do
    nil -> Application.get_env(:elektrine, :dns, []) |> Keyword.get(:nameservers, [])
    "" -> []
    value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

dns_soa_rname =
  case System.get_env("DNS_SOA_RNAME") do
    nil -> Application.get_env(:elektrine, :dns, []) |> Keyword.get(:soa_rname)
    "" -> nil
    value -> String.trim(value)
  end

dns_recursive_allow_cidrs =
  case System.get_env("DNS_RECURSIVE_ALLOW_CIDRS") do
    nil -> Application.get_env(:elektrine, :dns, []) |> Keyword.get(:recursive_allow_cidrs, [])
    "" -> []
    value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

dns_recursive_upstreams =
  case System.get_env("DNS_RECURSIVE_UPSTREAMS") do
    nil -> Application.get_env(:elektrine, :dns, []) |> Keyword.get(:recursive_upstreams, [])
    "" -> []
    value -> parse_dns_endpoints.(value)
  end

config :elektrine, :dns,
  authority_enabled: parse_bool_env.("DNS_AUTHORITY_ENABLED", false),
  recursive_enabled: parse_bool_env.("DNS_RECURSIVE_ENABLED", false),
  nameservers: dns_nameservers,
  soa_rname: dns_soa_rname,
  recursive_upstreams: dns_recursive_upstreams,
  recursive_allow_cidrs: dns_recursive_allow_cidrs,
  max_udp_payload:
    parse_int_env.(
      "DNS_MAX_UDP_PAYLOAD",
      Application.get_env(:elektrine, :dns, []) |> Keyword.get(:max_udp_payload, 1232)
    ),
  rate_limit_window_ms:
    parse_int_env.(
      "DNS_RATE_LIMIT_WINDOW_MS",
      Application.get_env(:elektrine, :dns, []) |> Keyword.get(:rate_limit_window_ms, 1000)
    ),
  udp_rate_limit_per_window:
    parse_int_env.(
      "DNS_UDP_RATE_LIMIT_PER_WINDOW",
      Application.get_env(:elektrine, :dns, []) |> Keyword.get(:udp_rate_limit_per_window, 200)
    ),
  tcp_rate_limit_per_window:
    parse_int_env.(
      "DNS_TCP_RATE_LIMIT_PER_WINDOW",
      Application.get_env(:elektrine, :dns, []) |> Keyword.get(:tcp_rate_limit_per_window, 50)
    ),
  udp_max_inflight:
    parse_int_env.(
      "DNS_UDP_MAX_INFLIGHT",
      Application.get_env(:elektrine, :dns, []) |> Keyword.get(:udp_max_inflight, 1024)
    ),
  tcp_max_inflight:
    parse_int_env.(
      "DNS_TCP_MAX_INFLIGHT",
      Application.get_env(:elektrine, :dns, []) |> Keyword.get(:tcp_max_inflight, 256)
    ),
  udp_port:
    parse_int_env.(
      "DNS_UDP_PORT",
      Application.get_env(:elektrine, :dns, []) |> Keyword.get(:udp_port, 5300)
    ),
  tcp_port:
    parse_int_env.(
      "DNS_TCP_PORT",
      Application.get_env(:elektrine, :dns, []) |> Keyword.get(:tcp_port, 5300)
    ),
  recursive_timeout:
    parse_int_env.(
      "DNS_RECURSIVE_TIMEOUT_MS",
      Application.get_env(:elektrine, :dns, []) |> Keyword.get(:recursive_timeout, 3000)
    )

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

messaging_federation_clock_skew_seconds =
  parse_int_env.("MESSAGING_FEDERATION_CLOCK_SKEW_SECONDS", 300)

messaging_federation_conformance_core_passed =
  parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_CORE_PASSED", true)

messaging_federation_conformance_ext_roles_passed =
  parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_EXT_ROLES_PASSED", true)

messaging_federation_conformance_ext_permissions_passed =
  parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_EXT_PERMISSIONS_PASSED", true)

messaging_federation_conformance_ext_threads_passed =
  parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_EXT_THREADS_PASSED", true)

messaging_federation_conformance_ext_presence_passed =
  parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_EXT_PRESENCE_PASSED", true)

messaging_federation_conformance_ext_moderation_passed =
  parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_EXT_MODERATION_PASSED", true)

messaging_federation_conformance_extensions = %{
  "urn:arbp:ext:roles:1" => messaging_federation_conformance_ext_roles_passed,
  "urn:arbp:ext:permissions:1" => messaging_federation_conformance_ext_permissions_passed,
  "urn:arbp:ext:threads:1" => messaging_federation_conformance_ext_threads_passed,
  "urn:arbp:ext:presence:1" => messaging_federation_conformance_ext_presence_passed,
  "urn:arbp:ext:moderation:1" => messaging_federation_conformance_ext_moderation_passed
}

messaging_federation_allow_insecure_http_transport =
  parse_bool_env.("MESSAGING_FEDERATION_ALLOW_INSECURE_HTTP_TRANSPORT", false)

config :elektrine, :messaging_federation,
  enabled: messaging_federation_enabled,
  identity_key_id: messaging_federation_identity_key_id,
  identity_keys: messaging_federation_identity_keys,
  identity_shared_secret: messaging_federation_identity_shared_secret,
  official_relay_operator: messaging_federation_official_relay_operator,
  official_relays: messaging_federation_official_relays,
  conformance_core_passed: messaging_federation_conformance_core_passed,
  conformance_extensions: messaging_federation_conformance_extensions,
  clock_skew_seconds: messaging_federation_clock_skew_seconds,
  allow_insecure_http_transport: messaging_federation_allow_insecure_http_transport,
  delivery_concurrency: messaging_federation_delivery_concurrency,
  delivery_timeout_ms: messaging_federation_delivery_timeout_ms,
  outbox_max_attempts: messaging_federation_outbox_max_attempts,
  outbox_base_backoff_seconds: messaging_federation_outbox_base_backoff_seconds,
  event_retention_days: messaging_federation_event_retention_days,
  outbox_retention_days: messaging_federation_outbox_retention_days,
  peers: messaging_federation_peers

bluesky_enabled =
  case System.get_env("BLUESKY_ENABLED", "false") do
    value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
    _ -> false
  end

bluesky_inbound_enabled =
  case System.get_env("BLUESKY_INBOUND_ENABLED", "false") do
    value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
    _ -> false
  end

bluesky_managed_enabled =
  case System.get_env("BLUESKY_MANAGED_ENABLED", "false") do
    value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
    _ -> false
  end

bluesky_service_url =
  case System.get_env("BLUESKY_SERVICE_URL") do
    nil -> "https://bsky.social"
    "" -> "https://bsky.social"
    value -> value
  end

bluesky_timeout_ms = parse_int_env.("BLUESKY_TIMEOUT_MS", 12_000)
bluesky_max_chars = parse_int_env.("BLUESKY_MAX_CHARS", 300)
bluesky_inbound_limit = parse_int_env.("BLUESKY_INBOUND_LIMIT", 50)

bluesky_managed_service_url =
  case System.get_env("BLUESKY_MANAGED_SERVICE_URL") do
    nil -> bluesky_service_url
    "" -> bluesky_service_url
    value -> value
  end

bluesky_managed_domain =
  case System.get_env("BLUESKY_MANAGED_DOMAIN") do
    nil -> nil
    "" -> nil
    value -> value
  end

bluesky_managed_admin_password =
  case System.get_env("BLUESKY_MANAGED_ADMIN_PASSWORD") do
    nil -> nil
    "" -> nil
    value -> value
  end

config :elektrine, :bluesky,
  enabled: bluesky_enabled,
  service_url: bluesky_service_url,
  timeout_ms: bluesky_timeout_ms,
  max_chars: bluesky_max_chars,
  inbound_enabled: bluesky_inbound_enabled,
  inbound_limit: bluesky_inbound_limit,
  managed_enabled: bluesky_managed_enabled,
  managed_service_url: bluesky_managed_service_url,
  managed_domain: bluesky_managed_domain,
  managed_admin_password: bluesky_managed_admin_password

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

turn_enabled = parse_bool_env.("TURN_ENABLED", false)
turn_host = first_present_env.(["TURN_HOST", "PHX_HOST"]) || runtime_primary_domain
turn_port = parse_int_env.("TURN_PORT", 3478)
turn_realm = first_present_env.(["TURN_REALM"]) || turn_host
turn_username_ttl_seconds = parse_int_env.("TURN_USERNAME_TTL_SECONDS", 3600)

turn_shared_secret = RuntimeSecrets.turn_shared_secret(runtime_env)

stun_uris =
  case System.get_env("STUN_URIS") do
    nil ->
      if turn_enabled do
        ["stun:#{turn_host}:#{turn_port}"]
      else
        []
      end

    "" ->
      []

    value ->
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end

turn_uris =
  case System.get_env("TURN_URIS") do
    nil ->
      if turn_enabled do
        [
          "turn:#{turn_host}:#{turn_port}?transport=udp",
          "turn:#{turn_host}:#{turn_port}?transport=tcp"
        ]
      else
        []
      end

    "" ->
      []

    value ->
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end

if turn_enabled or stun_uris != [] or turn_uris != [] do
  ice_servers = if stun_uris == [], do: [], else: [%{urls: stun_uris}]

  config :elektrine,
         :webrtc,
         Application.get_env(:elektrine, :webrtc, [])
         |> Keyword.merge(
           ice_servers: ice_servers,
           turn_uris: turn_uris,
           turn_shared_secret: turn_shared_secret,
           turn_username_ttl_seconds: turn_username_ttl_seconds,
           turn_realm: turn_realm
         )
end

config :elektrine,
  internal_api_key: derived_internal_api_key,
  session_signing_salt: RuntimeSecrets.session_signing_salt(runtime_env),
  session_encryption_salt: RuntimeSecrets.session_encryption_salt(runtime_env)

if :email in enabled_platform_modules do
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
  config :swoosh, :api_client, Swoosh.ApiClient.Hackney
end

# Configure encryption.
# In production, encryption is optional: if secrets are missing, encryption is disabled.
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

if config_env() == :prod do
  config :elektrine,
    encryption_enabled: encryption_configured,
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

  # Production paths - use persistent /data volume
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

  pool_size = env_int.("POOL_SIZE", 20)
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
      one of ELEKTRINE_MASTER_SECRET or SECRET_KEY_BASE must be set.
      ELEKTRINE_MASTER_SECRET is recommended for deriving internal runtime secrets.
      """

  session_signing_salt =
    RuntimeSecrets.session_signing_salt(runtime_env) || "chat_auth_signing_salt"

  present? = fn value -> is_binary(value) and String.trim(value) != "" end

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

  default_supported_domains = [email_domain]

  supported_domains_env =
    System.get_env("SUPPORTED_DOMAINS") || System.get_env("EMAIL_SUPPORTED_DOMAINS")

  supported_email_domains =
    ([primary_domain] ++ parse_domain_list.(supported_domains_env, default_supported_domains))
    |> Enum.uniq()

  profile_domains_env = System.get_env("PROFILE_BASE_DOMAINS")

  profile_base_domains =
    parse_domain_list.(profile_domains_env, [primary_domain])

  host = System.get_env("PHX_HOST") || primary_domain
  host_domain = normalize_domain.(host)

  all_public_domains =
    ([host_domain] ++ supported_email_domains ++ profile_base_domains)
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
    allow_insecure_receiver_webhook: false,
    receiver_webhook_secret: derived_receiver_webhook_secret,
    internal_signing_secret: derived_haraka_signing_secret,
    supported_domains: supported_email_domains,
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
    ip: {0, 0, 0, 0, 0, 0, 0, 0},
    port: port,
    http_1_options: [
      max_header_count: 50,
      max_header_length: 8_192
    ]
  ]

  onion_https =
    if onion_tls_enabled and File.regular?(onion_tls_certfile) and
         File.regular?(onion_tls_keyfile) do
      [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: onion_tls_port,
        cipher_suite: :strong,
        certfile: onion_tls_certfile,
        keyfile: onion_tls_keyfile,
        http_1_options: [
          max_header_count: 50,
          max_header_length: 8_192
        ]
      ]
    else
      nil
    end

  # Allowed origins for WebSocket connections
  # Includes primary domains, profile subdomains, and onion hosts.
  allowed_origins =
    all_public_domains
    |> Enum.flat_map(fn domain ->
      [
        "https://#{domain}",
        "https://www.#{domain}",
        "//*.#{domain}"
      ]
    end)
    |> Kernel.++(["//*.onion"])
    |> Kernel.++(parse_origin_list.(System.get_env("EXTRA_CHECK_ORIGINS")))
    |> Enum.uniq()

  endpoint_config = [
    url: [host: host, port: 443, scheme: "https"],
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

  turnstile_site_key = System.get_env("TURNSTILE_SITE_KEY")
  turnstile_secret_key = System.get_env("TURNSTILE_SECRET_KEY")
  turnstile_enabled = present?.(turnstile_site_key) and present?.(turnstile_secret_key)

  # Cloudflare Turnstile configuration for production (optional)
  config :elektrine, :turnstile,
    enabled: turnstile_enabled,
    skip_verification: not turnstile_enabled,
    site_key: turnstile_site_key,
    secret_key: turnstile_secret_key,
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

  r2_access_key_id = System.get_env("R2_ACCESS_KEY_ID")
  r2_secret_access_key = System.get_env("R2_SECRET_ACCESS_KEY")
  r2_endpoint = System.get_env("R2_ENDPOINT")
  r2_bucket_name = System.get_env("R2_BUCKET_NAME")
  r2_public_url = System.get_env("R2_PUBLIC_URL")
  local_uploads_dir = Path.join(to_string(:code.priv_dir(:elektrine)), "static/uploads")

  r2_configured =
    Enum.all?(
      [r2_access_key_id, r2_secret_access_key, r2_endpoint, r2_bucket_name],
      &present?.(&1)
    )

  if r2_configured do
    config :ex_aws,
      access_key_id: r2_access_key_id,
      secret_access_key: r2_secret_access_key,
      region: "auto",
      json_codec: Jason,
      s3: [
        scheme: "https://",
        host: r2_endpoint,
        region: "auto",
        port: 443
      ]

    config :elektrine, :uploads,
      adapter: :s3,
      bucket: r2_bucket_name,
      endpoint: r2_endpoint,
      # Optional: Custom domain if configured in R2
      public_url: r2_public_url,
      # Upload security limits
      # 5MB
      max_file_size: 5 * 1024 * 1024,
      max_image_width: 2048,
      max_image_height: 2048
  else
    config :elektrine, :uploads,
      adapter: :local,
      uploads_dir: local_uploads_dir,
      max_file_size: 5 * 1024 * 1024,
      max_background_size: 10 * 1024 * 1024,
      max_image_width: 2048,
      max_image_height: 2048
  end
end

# POP3 Server configuration
# Always use port 2110 (non-privileged port) to avoid permission issues.
# Keep test isolated from host mail daemons by letting test.exs own these ports.
if config_env() != :test do
  mail_enabled = parse_bool_env.("ELEKTRINE_ENABLE_MAIL", true)
  mail_tls_cert_path = System.get_env("MAIL_TLS_CERT_PATH")
  mail_tls_key_path = System.get_env("MAIL_TLS_KEY_PATH")
  imap_tls_cert_path = System.get_env("IMAP_TLS_CERT_PATH") || mail_tls_cert_path
  imap_tls_key_path = System.get_env("IMAP_TLS_KEY_PATH") || mail_tls_key_path
  pop3_tls_cert_path = System.get_env("POP3_TLS_CERT_PATH") || mail_tls_cert_path
  pop3_tls_key_path = System.get_env("POP3_TLS_KEY_PATH") || mail_tls_key_path

  mail_tls_path_present? = fn value -> is_binary(value) and String.trim(value) != "" end

  tls_opts_for = fn cert_path, key_path ->
    if mail_enabled and mail_tls_path_present?.(cert_path) and mail_tls_path_present?.(key_path) and
         File.regular?(cert_path) and File.regular?(key_path) do
      [certfile: cert_path, keyfile: key_path]
    else
      []
    end
  end

  imap_tls_opts = tls_opts_for.(imap_tls_cert_path, imap_tls_key_path)
  pop3_tls_opts = tls_opts_for.(pop3_tls_cert_path, pop3_tls_key_path)

  config :elektrine,
    pop3_enabled: mail_enabled and parse_bool_env.("POP3_ENABLED", true),
    pop3_port: parse_int_env.("POP3_PORT", 2110),
    pop3s_enabled: pop3_tls_opts != [] and parse_bool_env.("POP3S_ENABLED", true),
    pop3s_port: parse_int_env.("POP3S_PORT", 2995),
    pop3_tls_opts: pop3_tls_opts,
    imap_enabled: mail_enabled and parse_bool_env.("IMAP_ENABLED", true),
    imap_port: parse_int_env.("IMAP_PORT", 2143),
    imaps_enabled: imap_tls_opts != [] and parse_bool_env.("IMAPS_ENABLED", true),
    imaps_port: parse_int_env.("IMAPS_PORT", 2993),
    imap_tls_opts: imap_tls_opts,
    smtp_enabled: mail_enabled and parse_bool_env.("SMTP_ENABLED", true),
    smtp_port: parse_int_env.("SMTP_PORT", 2587)
end

# Stripe configuration for subscriptions
if System.get_env("STRIPE_SECRET_KEY") do
  config :stripity_stripe,
    api_key: System.get_env("STRIPE_SECRET_KEY"),
    signing_secret: System.get_env("STRIPE_WEBHOOK_SECRET")
end
