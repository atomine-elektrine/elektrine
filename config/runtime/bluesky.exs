import Config

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

blank_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil -> default
    "" -> default
    value -> value
  end
end

bluesky_service_url = blank_env.("BLUESKY_SERVICE_URL", "https://bsky.social")

config :elektrine, :bluesky,
  enabled: parse_bool_env.("BLUESKY_ENABLED", false),
  service_url: bluesky_service_url,
  timeout_ms: parse_int_env.("BLUESKY_TIMEOUT_MS", 12_000),
  max_chars: parse_int_env.("BLUESKY_MAX_CHARS", 300),
  inbound_enabled: parse_bool_env.("BLUESKY_INBOUND_ENABLED", false),
  inbound_limit: parse_int_env.("BLUESKY_INBOUND_LIMIT", 50),
  managed_enabled: parse_bool_env.("BLUESKY_MANAGED_ENABLED", false),
  managed_service_url: blank_env.("BLUESKY_MANAGED_SERVICE_URL", bluesky_service_url),
  managed_domain: blank_env.("BLUESKY_MANAGED_DOMAIN", nil),
  managed_admin_password: blank_env.("BLUESKY_MANAGED_ADMIN_PASSWORD", nil)
