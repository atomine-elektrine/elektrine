import Config

alias Elektrine.RuntimeSecrets

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

first_present_env = fn env_names ->
  Enum.find_value(env_names, fn env_name ->
    case System.get_env(env_name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end)
end

parse_uri_list = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      []

    value ->
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end
end

runtime_env = System.get_env()

runtime_primary_domain =
  System.get_env("PRIMARY_DOMAIN") ||
    Application.get_env(:elektrine, :primary_domain, "example.com")

turn_enabled = parse_bool_env.("TURN_ENABLED", false)
turn_host = first_present_env.(["TURN_HOST", "PHX_HOST"]) || runtime_primary_domain
turn_port = parse_int_env.("TURN_PORT", 3478)
turn_realm = first_present_env.(["TURN_REALM"]) || turn_host
turn_username_ttl_seconds = parse_int_env.("TURN_USERNAME_TTL_SECONDS", 3600)
turn_shared_secret = RuntimeSecrets.turn_shared_secret(runtime_env)

stun_uris =
  parse_uri_list.(
    "STUN_URIS",
    if(turn_enabled, do: ["stun:#{turn_host}:#{turn_port}"], else: [])
  )

turn_uris =
  parse_uri_list.(
    "TURN_URIS",
    if turn_enabled do
      [
        "turn:#{turn_host}:#{turn_port}?transport=udp",
        "turn:#{turn_host}:#{turn_port}?transport=tcp"
      ]
    else
      []
    end
  )

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
