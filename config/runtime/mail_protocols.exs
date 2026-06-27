import Config

parse_bool_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil -> default
    "" -> default
    value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
    value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] -> false
    _ -> default
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

# Keep test isolated from host mail daemons by letting test.exs own these ports.
if config_env() != :test do
  mail_enabled = parse_bool_env.("ELEKTRINE_ENABLE_MAIL", true)
  mail_tls_cert_path = System.get_env("MAIL_TLS_CERT_PATH")
  mail_tls_key_path = System.get_env("MAIL_TLS_KEY_PATH")
  imap_tls_cert_path = System.get_env("IMAP_TLS_CERT_PATH") || mail_tls_cert_path
  imap_tls_key_path = System.get_env("IMAP_TLS_KEY_PATH") || mail_tls_key_path
  pop3_tls_cert_path = System.get_env("POP3_TLS_CERT_PATH") || mail_tls_cert_path
  pop3_tls_key_path = System.get_env("POP3_TLS_KEY_PATH") || mail_tls_key_path
  smtp_tls_cert_path = System.get_env("SMTP_TLS_CERT_PATH") || mail_tls_cert_path
  smtp_tls_key_path = System.get_env("SMTP_TLS_KEY_PATH") || mail_tls_key_path

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
  smtp_tls_opts = tls_opts_for.(smtp_tls_cert_path, smtp_tls_key_path)

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
    smtp_port: parse_int_env.("SMTP_PORT", 2587),
    smtps_enabled: smtp_tls_opts != [] and parse_bool_env.("SMTPS_ENABLED", true),
    smtps_port: parse_int_env.("SMTPS_PORT", 2465),
    smtp_tls_opts: smtp_tls_opts
end
