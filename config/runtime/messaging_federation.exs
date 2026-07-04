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

parse_json_list_env = fn env_name ->
  case System.get_env(env_name) do
    nil ->
      []

    "" ->
      []

    json ->
      case Jason.decode(json) do
        {:ok, values} when is_list(values) -> values
        _ -> []
      end
  end
end

messaging_federation_conformance_extensions = %{
  "urn:arbp:ext:roles:1" =>
    parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_EXT_ROLES_PASSED", true),
  "urn:arbp:ext:permissions:1" =>
    parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_EXT_PERMISSIONS_PASSED", true),
  "urn:arbp:ext:threads:1" =>
    parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_EXT_THREADS_PASSED", true),
  "urn:arbp:ext:presence:1" =>
    parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_EXT_PRESENCE_PASSED", true),
  "urn:arbp:ext:moderation:1" =>
    parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_EXT_MODERATION_PASSED", true)
}

messaging_federation_identity_key_id =
  case System.get_env("MESSAGING_FEDERATION_IDENTITY_KEY_ID") do
    nil -> "default"
    "" -> "default"
    value -> value
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

config :elektrine, :messaging_federation,
  enabled: parse_bool_env.("MESSAGING_FEDERATION_ENABLED", true),
  identity_key_id: messaging_federation_identity_key_id,
  identity_keys: parse_json_list_env.("MESSAGING_FEDERATION_IDENTITY_KEYS_JSON"),
  identity_shared_secret: messaging_federation_identity_shared_secret,
  official_relay_operator: messaging_federation_official_relay_operator,
  official_relays: parse_json_list_env.("MESSAGING_FEDERATION_OFFICIAL_RELAYS_JSON"),
  conformance_core_passed: parse_bool_env.("MESSAGING_FEDERATION_CONFORMANCE_CORE_PASSED", true),
  conformance_extensions: messaging_federation_conformance_extensions,
  clock_skew_seconds: parse_int_env.("MESSAGING_FEDERATION_CLOCK_SKEW_SECONDS", 300),
  allow_insecure_http_transport:
    parse_bool_env.("MESSAGING_FEDERATION_ALLOW_INSECURE_HTTP_TRANSPORT", false),
  delivery_concurrency: parse_int_env.("MESSAGING_FEDERATION_DELIVERY_CONCURRENCY", 6),
  delivery_timeout_ms: parse_int_env.("MESSAGING_FEDERATION_DELIVERY_TIMEOUT_MS", 12_000),
  outbox_max_attempts: parse_int_env.("MESSAGING_FEDERATION_OUTBOX_MAX_ATTEMPTS", 8),
  outbox_base_backoff_seconds:
    parse_int_env.("MESSAGING_FEDERATION_OUTBOX_BASE_BACKOFF_SECONDS", 5),
  event_retention_days: parse_int_env.("MESSAGING_FEDERATION_EVENT_RETENTION_DAYS", 14),
  outbox_retention_days: parse_int_env.("MESSAGING_FEDERATION_OUTBOX_RETENTION_DAYS", 30),
  ingress_rate_limit_enabled:
    parse_bool_env.("MESSAGING_FEDERATION_INGRESS_RATE_LIMIT_ENABLED", true),
  ingress_peer_durable_events_per_minute:
    parse_int_env.("MESSAGING_FEDERATION_INGRESS_PEER_DURABLE_EVENTS_PER_MINUTE", 600),
  ingress_peer_ephemeral_items_per_minute:
    parse_int_env.("MESSAGING_FEDERATION_INGRESS_PEER_EPHEMERAL_ITEMS_PER_MINUTE", 1200),
  ingress_peer_sync_requests_per_minute:
    parse_int_env.("MESSAGING_FEDERATION_INGRESS_PEER_SYNC_REQUESTS_PER_MINUTE", 10),
  ingress_peer_replay_requests_per_minute:
    parse_int_env.("MESSAGING_FEDERATION_INGRESS_PEER_REPLAY_REQUESTS_PER_MINUTE", 60),
  ingress_room_durable_events_per_minute:
    parse_int_env.("MESSAGING_FEDERATION_INGRESS_ROOM_DURABLE_EVENTS_PER_MINUTE", 240),
  ingress_rate_limit_exempt_domains:
    parse_json_list_env.("MESSAGING_FEDERATION_INGRESS_RATE_LIMIT_EXEMPT_DOMAINS_JSON"),
  peers: parse_json_list_env.("MESSAGING_FEDERATION_PEERS_JSON")
