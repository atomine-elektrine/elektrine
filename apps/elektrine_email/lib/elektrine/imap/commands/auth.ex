defmodule Elektrine.IMAP.Commands.Auth do
  @moduledoc "IMAP authentication and session-security commands (STARTTLS, AUTHENTICATE, LOGIN)."

  require Logger

  alias Elektrine.Constants
  alias Elektrine.IMAP.Commands
  alias Elektrine.IMAP.Helpers
  alias Elektrine.Mail.Socket
  alias Elektrine.Mail.Telemetry, as: MailTelemetry
  alias Elektrine.MailAuth.RateLimiter, as: MailAuthRateLimiter

  def handle_starttls(tag, state) do
    cond do
      secure_transport?(state) ->
        Helpers.send_response(state.socket, "#{tag} BAD STARTTLS not valid when TLS is active")
        {:continue, state}

      !starttls_available?(state) ->
        Helpers.send_response(state.socket, "#{tag} NO STARTTLS not available")
        {:continue, state}

      true ->
        Helpers.send_response(state.socket, "#{tag} OK Begin TLS negotiation now")

        case Socket.starttls(state.socket, state.tls_opts) do
          {:ok, tls_socket} ->
            Socket.setopts(tls_socket, [
              {:active, false},
              {:packet, :line},
              {:keepalive, true},
              {:nodelay, true},
              {:send_timeout, Constants.imap_send_timeout_ms()},
              {:recbuf, 65_536},
              {:sndbuf, 65_536}
            ])

            {:continue,
             %{
               state
               | socket: tls_socket,
                 transport: :ssl,
                 authenticated: false,
                 user: nil,
                 username: nil,
                 mailbox: nil,
                 selected_folder: nil,
                 messages: [],
                 recent_message_ids: MapSet.new(),
                 folder_key: nil,
                 message_flags: %{},
                 idle_session_id: nil,
                 idle_start: nil,
                 auth_method: nil,
                 auth_app_password_id: nil,
                 initial_data: nil,
                 state: :not_authenticated
             }}

          {:error, reason} ->
            Logger.warning("IMAP STARTTLS failed: #{inspect(reason)}")
            {:logout, state}
        end
    end
  end

  def handle_authenticate(tag, args, state) do
    if auth_allowed?(state) do
      case parse_authenticate_args(args) do
        {:ok, "PLAIN", nil} ->
          Helpers.send_response(state.socket, "+")

          case Socket.recv(state.socket, 0, 60_000) do
            {:ok, data} ->
              authenticate_plain_payload(tag, data, state)

            {:error, _} ->
              Helpers.send_response(state.socket, "#{tag} NO AUTHENTICATE failed")
              {:continue, state}
          end

        {:ok, "PLAIN", initial_response} ->
          authenticate_plain_payload(tag, initial_response, state)

        {:ok, "LOGIN", nil} ->
          Helpers.send_response(state.socket, "+ VXNlcm5hbWU6")

          case Socket.recv(state.socket, 0, 60_000) do
            {:ok, username_data} ->
              case Helpers.decode_auth_login_line(username_data) do
                {:ok, "*"} ->
                  Helpers.send_response(state.socket, "#{tag} BAD AUTHENTICATE cancelled")
                  {:continue, state}

                {:ok, username} ->
                  Helpers.send_response(state.socket, "+ UGFzc3dvcmQ6")

                  case Socket.recv(state.socket, 0, 60_000) do
                    {:ok, password_data} ->
                      case Helpers.decode_auth_login_line(password_data) do
                        {:ok, "*"} ->
                          Helpers.send_response(state.socket, "#{tag} BAD AUTHENTICATE cancelled")
                          {:continue, state}

                        {:ok, password} ->
                          do_authenticate(tag, username, password, state)

                        :error ->
                          Helpers.send_response(state.socket, "#{tag} NO AUTHENTICATE failed")
                          {:continue, state}
                      end

                    {:error, _} ->
                      Helpers.send_response(state.socket, "#{tag} NO AUTHENTICATE failed")
                      {:continue, state}
                  end

                :error ->
                  Helpers.send_response(state.socket, "#{tag} NO AUTHENTICATE failed")
                  {:continue, state}
              end

            {:error, _} ->
              Helpers.send_response(state.socket, "#{tag} NO AUTHENTICATE failed")
              {:continue, state}
          end

        {:ok, "LOGIN", _initial_response} ->
          Helpers.send_response(
            state.socket,
            "#{tag} BAD Unexpected initial response for AUTHENTICATE LOGIN"
          )

          {:continue, state}

        {:ok, _mechanism, _initial_response} ->
          Helpers.send_response(state.socket, "#{tag} NO Unsupported authentication mechanism")
          {:continue, state}

        {:error, :missing_mechanism} ->
          Helpers.send_response(state.socket, "#{tag} BAD Missing authentication mechanism")
          {:continue, state}
      end
    else
      Helpers.send_response(state.socket, "#{tag} NO STARTTLS required before authentication")
      {:continue, state}
    end
  end

  defp parse_authenticate_args(nil), do: {:error, :missing_mechanism}

  defp parse_authenticate_args(args) do
    case String.trim(args) do
      "" ->
        {:error, :missing_mechanism}

      trimmed ->
        case String.split(trimmed, ~r/\s+/, parts: 2) do
          [mechanism] ->
            {:ok, String.upcase(mechanism), nil}

          [mechanism, initial_response] ->
            {:ok, String.upcase(mechanism), String.trim(initial_response)}
        end
    end
  end

  defp authenticate_plain_payload(tag, payload, state) do
    case Helpers.decode_auth_plain(payload) do
      {:ok, username, password} ->
        do_authenticate(tag, username, password, state)

      {:error, :cancelled} ->
        Helpers.send_response(state.socket, "#{tag} BAD AUTHENTICATE cancelled")
        {:continue, state}

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} NO AUTHENTICATE failed")
        {:continue, state}
    end
  end

  def handle_login(tag, args, state) do
    if auth_allowed?(state) do
      case Helpers.parse_login_args(args) do
        {:ok, username, password} ->
          do_authenticate(tag, username, password, state)

        {:error, _} ->
          Helpers.send_response(state.socket, "#{tag} BAD Invalid LOGIN arguments")
          {:continue, state}
      end
    else
      Helpers.send_response(state.socket, "#{tag} NO STARTTLS required before authentication")
      {:continue, state}
    end
  end

  defp do_authenticate(tag, username, password, state) do
    ip_string = state.client_ip

    case check_auth_rate_limits(ip_string, username) do
      :ok ->
        case authenticate_user(username, password) do
          {:ok, user, mailbox, auth} ->
            Elektrine.IMAP.RateLimiter.clear_attempts(ip_string)
            MailAuthRateLimiter.clear_attempts(:imap, username)
            MailTelemetry.auth(:imap, :success, %{source: :login})

            Helpers.send_response(
              state.socket,
              "#{tag} OK [CAPABILITY #{Commands.capability_string(%{state | state: :authenticated})}] Logged in"
            )

            authenticated_state =
              Map.merge(state, %{
                authenticated: true,
                user: user,
                username: username,
                mailbox: mailbox,
                uid_validity: mailbox.id,
                recent_message_ids: MapSet.new(),
                folder_key: nil,
                state: :authenticated
              })
              |> put_mail_auth_state(auth)

            {:continue, authenticated_state}

          {:error, reason} ->
            Elektrine.IMAP.RateLimiter.record_failure(ip_string)
            MailAuthRateLimiter.record_failure(:imap, username)
            maybe_alert_auth_failure_pressure(ip_string, username)

            Logger.warning(
              "IMAP login failed: user=#{Helpers.redact_email(username)} ip=#{ip_string}"
            )

            MailTelemetry.auth(:imap, :failure, %{reason: reason, source: :login})
            Helpers.send_response(state.socket, "#{tag} NO Authentication failed")
            {:continue, state}
        end

      {:error, {:ip, :rate_limited}} ->
        Logger.warning(
          "IMAP rate limited by IP: ip=#{ip_string} user=#{Helpers.redact_email(username)}"
        )

        MailTelemetry.auth(:imap, :rate_limited, %{ratelimit: :ip, source: :login})
        Helpers.send_response(state.socket, "#{tag} NO Too many failed attempts")
        :timer.sleep(1000)
        {:logout, state}

      {:error, {:ip, :blocked}} ->
        Logger.warning("IMAP blocked IP: ip=#{ip_string} user=#{Helpers.redact_email(username)}")
        MailTelemetry.auth(:imap, :rate_limited, %{ratelimit: :ip_blocked, source: :login})
        Helpers.send_response(state.socket, "#{tag} NO IP temporarily blocked")
        {:logout, state}

      {:error, {:account, :rate_limited}} ->
        Logger.warning(
          "IMAP rate limited by account key: ip=#{ip_string} user=#{Helpers.redact_email(username)}"
        )

        MailTelemetry.auth(:imap, :rate_limited, %{ratelimit: :account, source: :login})
        Helpers.send_response(state.socket, "#{tag} NO Too many failed attempts")
        :timer.sleep(1000)
        {:logout, state}

      {:error, {:account, :blocked}} ->
        Logger.warning(
          "IMAP blocked account key: ip=#{ip_string} user=#{Helpers.redact_email(username)}"
        )

        MailTelemetry.auth(:imap, :rate_limited, %{ratelimit: :account_blocked, source: :login})
        Helpers.send_response(state.socket, "#{tag} NO Account temporarily blocked")
        {:logout, state}
    end
  end

  defp check_auth_rate_limits(ip_string, username) do
    case Elektrine.IMAP.RateLimiter.check_attempt(ip_string) do
      {:ok, _attempts_left} ->
        case MailAuthRateLimiter.check_attempt(:imap, username) do
          {:ok, _remaining} -> :ok
          {:error, reason} -> {:error, {:account, reason}}
        end

      {:error, reason} ->
        {:error, {:ip, reason}}
    end
  end

  defp maybe_alert_auth_failure_pressure(ip_string, username) do
    ip_failures =
      Elektrine.IMAP.RateLimiter.get_status(ip_string) |> get_in([:attempts, 60, :count]) || 0

    account_failures = MailAuthRateLimiter.failure_count(:imap, username)

    if ip_failures >= 4 or account_failures >= 4 do
      Logger.warning(
        "IMAP auth failure spike: ip=#{ip_string} ip_failures=#{ip_failures} account_failures=#{account_failures}"
      )
    end
  end

  defp authenticate_user(username, password) do
    case Elektrine.Accounts.authenticate_with_app_password_info(username, password) do
      {:ok, user, app_password} ->
        Elektrine.Accounts.record_imap_access(user.id)

        case get_or_create_mailbox(user) do
          {:ok, mailbox} -> {:ok, user, mailbox, {:app_password, app_password.id}}
          _ -> {:error, :mailbox_error}
        end

      {:error, {:invalid_token, user}} ->
        try_regular_password_auth(user, password)

      {:error, :user_not_found} ->
        {:error, :authentication_failed}
    end
  end

  defp try_regular_password_auth(user, password) do
    if has_2fa_enabled?(user) do
      {:error, :requires_app_password}
    else
      case Elektrine.Accounts.verify_user_password(user, password) do
        {:ok, _user} ->
          Elektrine.Accounts.record_imap_access(user.id)

          case get_or_create_mailbox(user) do
            {:ok, mailbox} -> {:ok, user, mailbox, :account_password}
            _ -> {:error, :mailbox_error}
          end

        {:error, _} ->
          {:error, :authentication_failed}
      end
    end
  end

  defp has_2fa_enabled?(user) do
    user.two_factor_enabled == true
  end

  defp get_or_create_mailbox(user) do
    case Elektrine.Email.ensure_user_has_mailbox(user) do
      {:ok, mailbox} -> {:ok, mailbox}
      _ -> {:error, :mailbox_error}
    end
  end

  defp put_mail_auth_state(state, {:app_password, app_password_id}) do
    Phoenix.PubSub.subscribe(Elektrine.PubSub, "mail_auth:app_password:#{app_password_id}")

    state
    |> Map.put(:auth_method, :app_password)
    |> Map.put(:auth_app_password_id, app_password_id)
  end

  defp put_mail_auth_state(state, :account_password) do
    Phoenix.PubSub.subscribe(Elektrine.PubSub, "mail_auth:user:#{state.user.id}")

    state
    |> Map.put(:auth_method, :account_password)
    |> Map.put(:auth_app_password_id, nil)
  end

  def starttls_available?(state) do
    not secure_transport?(state) and Socket.tls_available?(Map.get(state, :tls_opts, []))
  end

  def auth_allowed?(state) do
    # NOTE: prod sets :allow_insecure_auth explicitly from config, so this
    # function default is only hit by callers that omit the key. It stays `true`
    # (matching existing auth tests + capability advertising); the actual
    # insecure-auth policy is enforced by config, not this default.
    secure_transport?(state) or Map.get(state, :allow_insecure_auth, true)
  end

  defp secure_transport?(state) do
    socket = Map.get(state, :socket)
    Map.get(state, :transport) == :ssl or match?({:sslsocket, _, _}, socket)
  end
end
