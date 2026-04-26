defmodule ElektrineWeb.AdminSecurity do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  alias Elektrine.Accounts.Passkeys
  alias ElektrineWeb.Endpoint

  @admin_auth_method_key :admin_auth_method
  @admin_auth_at_key :admin_auth_at
  @admin_access_expires_at_key :admin_access_expires_at
  @admin_elevated_until_key :admin_elevated_until
  @admin_device_fingerprint_key :admin_device_fingerprint
  @admin_device_credential_key :admin_device_credential_fp
  @admin_last_resign_at_key :admin_last_resign_at

  @elevation_intent_salt "admin elevation intent"
  @action_intent_salt "admin action intent"
  @action_grant_salt "admin action grant"

  @default_access_ttl_seconds 15 * 60
  @default_elevation_ttl_seconds 5 * 60
  @default_action_grant_ttl_seconds 90
  @default_intent_ttl_seconds 3 * 60
  @default_replay_ttl_seconds 10 * 60

  @mutating_methods ~w(POST PUT PATCH DELETE)
  @grantable_methods ["GET" | @mutating_methods]
  @admin_root_path "/pripyat"
  @admin_security_path "/pripyat/security"

  def initialize_admin_session(conn, user, opts \\ [])

  def initialize_admin_session(conn, %{is_admin: true}, opts) do
    now = now_seconds()
    auth_method = normalize_auth_method(opts[:auth_method] || opts[:method] || :password)
    credential_fp = credential_fingerprint(opts[:passkey_credential_id])
    device_fp = request_fingerprint(conn, credential_fp)

    conn
    |> put_session(@admin_auth_method_key, auth_method)
    |> put_session(@admin_auth_at_key, now)
    |> put_session(@admin_access_expires_at_key, now + access_ttl_seconds())
    |> put_session(@admin_device_credential_key, credential_fp)
    |> put_session(@admin_device_fingerprint_key, device_fp)
    |> maybe_set_initial_elevation(auth_method, now)
  end

  def initialize_admin_session(conn, _user, _opts), do: conn

  def enforce_controller_security(conn, user) do
    with {:ok, conn} <- ensure_passkey_enrolled(conn, user),
         {:ok, conn} <- ensure_device_fingerprint(conn),
         {:ok, conn} <- ensure_admin_access_ttl(conn),
         {:ok, conn} <- ensure_elevated(conn),
         {:ok, conn} <- ensure_action_grant(conn, user) do
      conn
    else
      {:error, reason, conn} ->
        handle_controller_security_failure(conn, user, reason)
    end
  end

  def validate_live_admin_session(session, user) when is_map(session) do
    with :ok <- ensure_live_passkey_enrolled(user),
         :ok <- ensure_live_passkey_auth_method(session),
         :ok <- ensure_live_access_ttl(session) do
      ensure_live_elevation(session)
    end
  end

  def validate_live_admin_session(_session, _user), do: {:error, :elevation_required}

  def sign_elevation_intent(user, return_to) do
    payload = %{
      "admin_id" => user.id,
      "return_to" => normalize_return_to(return_to),
      "nonce" => nonce(),
      "iat" => now_seconds()
    }

    Phoenix.Token.sign(Endpoint, @elevation_intent_salt, payload)
  end

  def verify_elevation_intent(user, token) when is_binary(token) do
    with {:ok, payload} <-
           Phoenix.Token.verify(Endpoint, @elevation_intent_salt, token,
             max_age: intent_ttl_seconds()
           ),
         true <- payload["admin_id"] == user.id do
      {:ok, normalize_return_to(payload["return_to"])}
    else
      _ -> {:error, :invalid_intent}
    end
  end

  def verify_elevation_intent(_user, _token), do: {:error, :invalid_intent}

  def sign_action_intent(user, method, path) do
    payload = %{
      "admin_id" => user.id,
      "method" => method,
      "path" => path,
      "nonce" => nonce(),
      "iat" => now_seconds()
    }

    Phoenix.Token.sign(Endpoint, @action_intent_salt, payload)
  end

  def verify_action_intent(user, token) when is_binary(token) do
    with {:ok, payload} <-
           Phoenix.Token.verify(Endpoint, @action_intent_salt, token,
             max_age: intent_ttl_seconds()
           ),
         true <- payload["admin_id"] == user.id,
         {:ok, method, path} <- normalize_action_target(payload["method"], payload["path"]) do
      {:ok, method, path}
    else
      _ -> {:error, :invalid_intent}
    end
  end

  def verify_action_intent(_user, _token), do: {:error, :invalid_intent}

  def issue_action_grant(conn, user, method, path) do
    payload = %{
      "admin_id" => user.id,
      "method" => method,
      "path" => path,
      "jti" => nonce(),
      "device_fp" => get_session(conn, @admin_device_fingerprint_key),
      "iat" => now_seconds()
    }

    Phoenix.Token.sign(Endpoint, @action_grant_salt, payload)
  end

  def verify_action_grant(conn, user) do
    case action_grant_token(conn) do
      nil ->
        {:error, :action_grant_required, conn}

      token ->
        do_verify_action_grant(conn, user, token)
    end
  end

  def refresh_after_passkey(conn, credential_id) do
    now = now_seconds()
    credential_fp = credential_fingerprint(credential_id)
    elevated_until = now + elevation_ttl_seconds()
    access_until = now + access_ttl_seconds()
    device_fp = request_fingerprint(conn, credential_fp)

    conn
    |> put_session(@admin_auth_method_key, "passkey")
    |> put_session(@admin_auth_at_key, now)
    |> put_session(@admin_access_expires_at_key, access_until)
    |> put_session(@admin_elevated_until_key, elevated_until)
    |> put_session(@admin_device_credential_key, credential_fp)
    |> put_session(@admin_device_fingerprint_key, device_fp)
    |> put_session(@admin_last_resign_at_key, now)
  end

  def normalize_action_target(method, path) do
    with {:ok, normalized_method} <- normalize_http_method(method),
         {:ok, normalized_path} <- normalize_admin_path(path),
         false <- String.starts_with?(normalized_path, @admin_security_path) do
      {:ok, normalized_method, normalized_path}
    else
      _ -> {:error, :invalid_action_target}
    end
  end

  def normalize_return_to(return_to) when is_binary(return_to) do
    case URI.parse(return_to) do
      %URI{host: nil, scheme: nil, path: path, query: query}
      when is_binary(path) and path != "" ->
        if String.starts_with?(path, @admin_root_path) and
             not String.starts_with?(path, @admin_security_path) do
          maybe_with_query(path, query)
        else
          @admin_root_path
        end

      _ ->
        @admin_root_path
    end
  end

  def normalize_return_to(_), do: @admin_root_path

  def elevation_redirect_path(return_to) do
    "/pripyat/security/elevate?return_to=#{URI.encode_www_form(normalize_return_to(return_to))}"
  end

  def error_message(:passkey_required),
    do: "Admin access requires a registered passkey. Add one in Account Settings first."

  def error_message(:passkey_auth_required),
    do: "Admin access requires passkey-backed authentication."

  def error_message(:device_binding_failed),
    do: "Device binding check failed. Re-elevate your admin session."

  def error_message(:admin_access_expired),
    do: "Admin access expired. Re-elevate to continue."

  def error_message(:elevation_required),
    do: "Admin elevation is required for this page."

  def error_message(:action_grant_required),
    do: "Passkey confirmation is required for this action."

  def error_message(:action_grant_replayed),
    do: "That confirmation was already used. Please confirm the action again."

  def error_message(_), do: "Admin security verification failed. Re-elevate and try again."

  def action_grant_ttl_seconds,
    do: config(:action_grant_ttl_seconds, @default_action_grant_ttl_seconds)

  def recent_admin_confirmation?(session) when is_map(session) do
    now = now_seconds()

    case session_value(session, @admin_last_resign_at_key) do
      last_resign_at when is_integer(last_resign_at) ->
        now - last_resign_at <= action_grant_ttl_seconds()

      _ ->
        false
    end
  end

  def recent_admin_confirmation?(_session), do: false

  defp ensure_passkey_enrolled(conn, user) do
    if passkey_required?() and not Passkeys.has_passkeys?(user) do
      {:error, :passkey_required, conn}
    else
      ensure_passkey_auth_method(conn)
    end
  end

  defp ensure_passkey_auth_method(conn) do
    if passkey_required?() and get_session(conn, @admin_auth_method_key) != "passkey" do
      {:error, :passkey_auth_required, conn}
    else
      {:ok, conn}
    end
  end

  defp ensure_live_passkey_enrolled(user) do
    if passkey_required?() and not Passkeys.has_passkeys?(user) do
      {:error, :passkey_required}
    else
      :ok
    end
  end

  defp ensure_live_passkey_auth_method(session) do
    if passkey_required?() and session_value(session, @admin_auth_method_key) != "passkey" do
      {:error, :passkey_auth_required}
    else
      :ok
    end
  end

  defp ensure_device_fingerprint(conn) do
    stored = get_session(conn, @admin_device_fingerprint_key)
    credential_fp = get_session(conn, @admin_device_credential_key)
    current = request_fingerprint(conn, credential_fp)

    cond do
      is_nil(stored) ->
        {:ok, put_session(conn, @admin_device_fingerprint_key, current)}

      secure_compare(stored, current) ->
        {:ok, conn}

      true ->
        {:error, :device_binding_failed, conn}
    end
  end

  defp ensure_admin_access_ttl(conn) do
    now = now_seconds()

    case get_session(conn, @admin_access_expires_at_key) do
      expires_at when is_integer(expires_at) ->
        if expires_at >= now do
          {:ok, conn}
        else
          {:error, :admin_access_expired, conn}
        end

      _ ->
        {:error, :admin_access_expired, conn}
    end
  end

  defp ensure_live_access_ttl(session) do
    now = now_seconds()

    case session_value(session, @admin_access_expires_at_key) do
      expires_at when is_integer(expires_at) ->
        if expires_at >= now do
          :ok
        else
          {:error, :admin_access_expired}
        end

      _ ->
        {:error, :admin_access_expired}
    end
  end

  defp ensure_elevated(conn) do
    if String.starts_with?(conn.request_path, @admin_security_path) do
      {:ok, conn}
    else
      now = now_seconds()

      case get_session(conn, @admin_elevated_until_key) do
        elevated_until when is_integer(elevated_until) ->
          if elevated_until >= now do
            {:ok, conn}
          else
            {:error, :elevation_required, conn}
          end

        _ ->
          {:error, :elevation_required, conn}
      end
    end
  end

  defp ensure_live_elevation(session) do
    now = now_seconds()

    case session_value(session, @admin_elevated_until_key) do
      elevated_until when is_integer(elevated_until) ->
        if elevated_until >= now do
          :ok
        else
          {:error, :elevation_required}
        end

      _ ->
        {:error, :elevation_required}
    end
  end

  defp ensure_action_grant(conn, user) do
    if requires_action_grant?(conn) do
      verify_action_grant(conn, user)
    else
      {:ok, conn}
    end
  end

  defp do_verify_action_grant(conn, user, token) do
    with {:ok, payload} <-
           Phoenix.Token.verify(Endpoint, @action_grant_salt, token,
             max_age: action_grant_ttl_seconds()
           ),
         true <- payload["admin_id"] == user.id,
         true <- payload["method"] == conn.method,
         true <- payload["path"] == conn.request_path,
         true <- grant_matches_device?(conn, payload["device_fp"]),
         :ok <- consume_grant_nonce(payload["jti"]) do
      {:ok, conn}
    else
      {:error, :replayed} ->
        {:error, :action_grant_replayed, conn}

      _ ->
        {:error, :action_grant_required, conn}
    end
  end

  defp consume_grant_nonce(jti) when is_binary(jti) do
    key = {:admin_action_grant_nonce, jti}

    case Cachex.get(:app_cache, key) do
      {:ok, nil} ->
        Cachex.put(:app_cache, key, true, ttl: :timer.seconds(replay_ttl_seconds()))
        :ok

      {:ok, _} ->
        {:error, :replayed}

      _ ->
        {:error, :replayed}
    end
  end

  defp consume_grant_nonce(_), do: {:error, :replayed}

  defp grant_matches_device?(conn, payload_device_fp) when is_binary(payload_device_fp) do
    secure_compare(payload_device_fp, get_session(conn, @admin_device_fingerprint_key))
  end

  defp grant_matches_device?(_conn, _payload_device_fp), do: false

  defp action_grant_token(conn) do
    conn.params["_admin_action_grant"] || List.first(get_req_header(conn, "x-admin-action-grant"))
  end

  defp requires_action_grant?(conn) do
    conn.method in @mutating_methods and
      String.starts_with?(conn.request_path, @admin_root_path) and
      not String.starts_with?(conn.request_path, @admin_security_path)
  end

  defp maybe_set_initial_elevation(conn, "passkey", now) do
    conn
    |> put_session(@admin_elevated_until_key, now + elevation_ttl_seconds())
    |> put_session(@admin_last_resign_at_key, now)
  end

  defp maybe_set_initial_elevation(conn, _auth_method, _now) do
    conn
    |> delete_session(@admin_elevated_until_key)
    |> delete_session(@admin_last_resign_at_key)
  end

  defp derive_return_to(conn) do
    if conn.method == "GET" do
      normalize_return_to(request_path_with_query(conn))
    else
      referer_return_to(conn) || @admin_root_path
    end
  end

  defp handle_controller_security_failure(%{method: "GET"} = conn, user, reason) do
    return_to = derive_return_to(conn)

    conn
    |> maybe_put_error_flash(error_message(reason))
    |> put_layout(html: {ElektrineWeb.Layouts, :admin})
    |> put_view(html: ElektrineWeb.AdminHTML)
    |> render(:elevate,
      return_to: return_to,
      has_passkeys: Passkeys.has_passkeys?(user)
    )
    |> halt()
  end

  defp handle_controller_security_failure(conn, _user, reason) do
    conn
    |> maybe_put_error_flash(error_message(reason))
    |> redirect(to: elevation_redirect_path(derive_return_to(conn)))
    |> halt()
  end

  defp referer_return_to(conn) do
    case get_req_header(conn, "referer") do
      [referer | _] ->
        case URI.parse(referer) do
          %URI{path: path, query: query} when is_binary(path) ->
            normalize_return_to(maybe_with_query(path, query))

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp request_path_with_query(%Plug.Conn{request_path: request_path, query_string: ""}),
    do: request_path

  defp request_path_with_query(%Plug.Conn{
         request_path: request_path,
         query_string: query_string
       }),
       do: request_path <> "?" <> query_string

  defp maybe_put_error_flash(conn, message) do
    if Map.has_key?(conn.private, :phoenix_flash) do
      put_flash(conn, :error, message)
    else
      conn
    end
  end

  defp normalize_auth_method(method) when is_atom(method), do: Atom.to_string(method)
  defp normalize_auth_method(method) when is_binary(method), do: String.downcase(method)
  defp normalize_auth_method(_), do: "password"

  defp normalize_http_method(method) when is_binary(method) do
    normalized = method |> String.trim() |> String.upcase()

    if normalized in @grantable_methods,
      do: {:ok, normalized},
      else: {:error, :invalid_method}
  end

  defp normalize_http_method(_), do: {:error, :invalid_method}

  defp normalize_admin_path(path) when is_binary(path) do
    case URI.parse(path) do
      %URI{host: nil, scheme: nil, path: request_path} when is_binary(request_path) ->
        if String.starts_with?(request_path, @admin_root_path) do
          {:ok, request_path}
        else
          {:error, :invalid_path}
        end

      _ ->
        {:error, :invalid_path}
    end
  end

  defp normalize_admin_path(_), do: {:error, :invalid_path}

  defp maybe_with_query(path, nil), do: path
  defp maybe_with_query(path, ""), do: path
  defp maybe_with_query(path, query), do: path <> "?" <> query

  defp request_fingerprint(conn, credential_fp) do
    user_agent = List.first(get_req_header(conn, "user-agent")) || ""
    accept_language = List.first(get_req_header(conn, "accept-language")) || ""
    sec_ch_ua = List.first(get_req_header(conn, "sec-ch-ua")) || ""

    [user_agent, accept_language, sec_ch_ua, credential_fp || ""]
    |> Enum.join("|")
    |> hash()
  end

  defp credential_fingerprint(credential_id) when is_binary(credential_id),
    do: hash(credential_id)

  defp credential_fingerprint(_), do: nil

  defp hash(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp session_value(session, key) when is_map(session) do
    session[Atom.to_string(key)] || session[key]
  end

  defp nonce do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp now_seconds do
    System.system_time(:second)
  end

  defp passkey_required? do
    config(:require_passkey, true)
  end

  defp access_ttl_seconds do
    config(:access_ttl_seconds, @default_access_ttl_seconds)
  end

  defp elevation_ttl_seconds do
    config(:elevation_ttl_seconds, @default_elevation_ttl_seconds)
  end

  defp intent_ttl_seconds do
    config(:intent_ttl_seconds, @default_intent_ttl_seconds)
  end

  defp replay_ttl_seconds do
    config(:replay_ttl_seconds, @default_replay_ttl_seconds)
  end

  defp config(key, default) do
    :elektrine
    |> Application.get_env(:admin_security, [])
    |> Keyword.get(key, default)
  end
end
