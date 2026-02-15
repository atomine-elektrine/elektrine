defmodule Elektrine.SMTP.Server do
  @moduledoc """
  SMTP server implementation for Elektrine email system.
  Provides SMTP protocol support for sending emails from email clients.
  """

  use GenServer
  require Logger
  alias Elektrine.Constants
  alias Elektrine.Mail.Telemetry, as: MailTelemetry
  alias Elektrine.MailAuth.RateLimiter, as: MailAuthRateLimiter
  alias Elektrine.ProxyProtocol

  # Security limits
  @max_data_size Constants.smtp_max_data_size()
  @max_connections Constants.smtp_max_connections()
  @max_connections_per_ip Constants.smtp_max_connections_per_ip()
  @max_recipients Constants.smtp_max_recipients()
  @slow_command_threshold_us 750_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    port = Keyword.get(opts, :port, Application.get_env(:elektrine, :smtp_port, 2587))

    case :gen_tcp.listen(port, [
           # CRITICAL: Return data as binary, not charlist, to preserve UTF-8 encoding
           :binary,
           {:active, false},
           {:packet, :line},
           # Security: limit command line length
           {:packet_size, 8192},
           {:reuseaddr, true},
           {:ip, {0, 0, 0, 0}},
           {:backlog, 100},
           {:keepalive, true},
           {:send_timeout, Constants.smtp_send_timeout_ms()},
           {:send_timeout_close, true}
         ]) do
      {:ok, socket} ->
        # Create ETS table for connection tracking
        :ets.new(:smtp_active_connections, [:set, :public, :named_table])
        :ets.insert(:smtp_active_connections, {:total, 0})
        spawn_link(fn -> accept_loop(socket) end)
        {:ok, %{socket: socket, port: port, connections: 0}}

      {:error, :eaddrinuse} ->
        Logger.error("SMTP server failed: Port #{port} is already in use")
        {:ok, %{socket: nil, port: port, connections: 0, error: :port_in_use}}

      {:error, reason} ->
        Logger.error("Failed to start SMTP server on port #{port}: #{inspect(reason)}")
        {:ok, %{socket: nil, port: port, connections: 0, error: reason}}
    end
  end

  defp accept_loop(socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        # Parse PROXY protocol to get real client IP (Fly.io support)
        {client_ip, initial_data} =
          case ProxyProtocol.parse_client_ip(client) do
            {:ok, ip, data} ->
              {normalize_ipv6_subnet(ip), data}

            {:error, _reason} ->
              # Failed to read PROXY protocol, try to get peer IP as fallback
              case :inet.peername(client) do
                {:ok, {ip, _port}} ->
                  ip_string = :inet.ntoa(ip) |> to_string() |> normalize_ipv6_subnet()
                  :gen_tcp.close(client)
                  {ip_string, nil}

                {:error, _} ->
                  # Connection already closed, skip this client
                  :gen_tcp.close(client)
                  {nil, nil}
              end
          end

        cond do
          # Connection already closed during PROXY parsing
          is_nil(client_ip) ->
            # Skip and continue accepting
            :ok

          # Connection limit exceeded
          !can_accept_connection?(client_ip) ->
            Logger.warning(
              "SMTP connection rejected from #{client_ip}: connection limit exceeded"
            )

            send_response(client, "421 Too many connections from your IP address")
            :gen_tcp.close(client)

          # Accept the connection
          true ->
            :inet.setopts(client, [
              {:keepalive, true},
              {:nodelay, true},
              {:send_timeout, Constants.smtp_send_timeout_ms()},
              # 64KB receive buffer
              {:recbuf, 65536},
              # 64KB send buffer
              {:sndbuf, 65536}
            ])

            # Track connection
            increment_connection_count(client_ip)

            # Spawn handler with cleanup on exit
            spawn(fn ->
              try do
                handle_client(client, client_ip, initial_data)
              after
                decrement_connection_count(client_ip)
              end
            end)
        end

        accept_loop(socket)

      {:error, reason} ->
        Logger.error("Accept failed: #{inspect(reason)}")
        :timer.sleep(1000)
        accept_loop(socket)
    end
  end

  defp handle_client(socket, client_ip, initial_data) do
    send_response(socket, "220 Elektrine SMTP server ready")

    state = %{
      socket: socket,
      client_ip: client_ip,
      authenticated: false,
      user: nil,
      user_id: nil,
      from: nil,
      to: [],
      data: "",
      state: :greeting,
      initial_data: initial_data
    }

    client_loop(state)
  end

  defp client_loop(state) do
    # If we have initial_data from PROXY protocol parsing, use it first
    {command_data, updated_state} =
      if state.initial_data do
        {state.initial_data, %{state | initial_data: nil}}
      else
        # SMTP timeout is typically 5 minutes (300000 ms)
        case :gen_tcp.recv(state.socket, 0, 300_000) do
          {:ok, data} ->
            {data, state}

          {:error, :timeout} ->
            send_response(state.socket, "421 Timeout")
            :gen_tcp.close(state.socket)
            {nil, state}

          {:error, :closed} ->
            :gen_tcp.close(state.socket)
            {nil, state}

          {:error, reason} ->
            Logger.error("SMTP receive error: #{inspect(reason)}")
            :gen_tcp.close(state.socket)
            {nil, state}
        end
      end

    if command_data do
      command = command_data |> to_string() |> String.trim()

      case handle_command(command, updated_state) do
        {:continue, new_state} ->
          client_loop(new_state)

        {:quit, _new_state} ->
          send_response(state.socket, "221 Bye")
          :gen_tcp.close(state.socket)
      end
    end
  end

  defp handle_command(command, state) do
    started_at = System.monotonic_time(:microsecond)

    {command_name, result} =
      case String.split(command, " ", parts: 2) do
        [cmd | args] ->
          normalized_cmd = String.upcase(cmd)
          args_str = if args == [], do: nil, else: List.first(args)

          handled =
            case normalized_cmd do
              "EHLO" -> handle_ehlo(args_str, state)
              "HELO" -> handle_helo(args_str, state)
              "AUTH" -> handle_auth(args_str, state)
              "MAIL" -> handle_mail(args_str, state)
              "RCPT" -> handle_rcpt(args_str, state)
              "DATA" -> handle_data(state)
              "RSET" -> handle_rset(state)
              "NOOP" -> handle_noop(state)
              "QUIT" -> handle_quit(state)
              _ -> handle_unknown(normalized_cmd, state)
            end

          {normalized_cmd, handled}

        _ ->
          send_response(state.socket, "500 Command not recognized")
          {"INVALID", {:continue, state}}
      end

    duration_us = System.monotonic_time(:microsecond) - started_at
    outcome = command_outcome(result)
    MailTelemetry.command(:smtp, command_name, duration_us, outcome)
    maybe_alert_slow_command(command_name, duration_us, state.client_ip)

    result
  end

  defp handle_ehlo(_domain, state) do
    send_response(state.socket, "250-elektrine.com")
    send_response(state.socket, "250-SIZE 52428800")
    send_response(state.socket, "250-8BITMIME")
    send_response(state.socket, "250-AUTH PLAIN LOGIN")
    send_response(state.socket, "250 HELP")
    {:continue, %{state | state: :ready}}
  end

  defp handle_helo(_domain, state) do
    send_response(state.socket, "250 elektrine.com")
    {:continue, %{state | state: :ready}}
  end

  defp handle_auth(args, state) do
    case parse_auth(args) do
      {:plain, credentials} ->
        handle_auth_plain(credentials, state)

      {:login, nil} ->
        # AUTH LOGIN without initial response - request username
        send_response(state.socket, "334 VXNlcm5hbWU6")
        handle_auth_login_flow(state)

      {:login, username} ->
        case decode_base64_line(username) do
          {:ok, "*"} ->
            send_response(state.socket, "501 Authentication cancelled")
            {:continue, state}

          {:ok, decoded_username} ->
            # AUTH LOGIN with username - request password
            send_response(state.socket, "334 UGFzc3dvcmQ6")
            handle_auth_login_password(decoded_username, state)

          :error ->
            send_response(state.socket, "535 Authentication failed")
            {:continue, state}
        end

      {:error, _} ->
        send_response(state.socket, "535 Authentication failed")
        {:continue, state}
    end
  end

  defp parse_auth(nil), do: {:error, :no_args}

  defp parse_auth(args) do
    case String.split(String.trim(args), " ", parts: 2) do
      [mechanism, value] ->
        case String.upcase(mechanism) do
          "PLAIN" -> {:plain, value}
          "LOGIN" -> {:login, value}
          _ -> {:error, :invalid_mechanism}
        end

      [mechanism] ->
        case String.upcase(mechanism) do
          "PLAIN" -> {:plain, nil}
          "LOGIN" -> {:login, nil}
          _ -> {:error, :invalid_mechanism}
        end

      _ ->
        {:error, :invalid_mechanism}
    end
  end

  defp handle_auth_plain(nil, state) do
    # AUTH PLAIN without initial response - request credentials
    send_response(state.socket, "334")

    case :gen_tcp.recv(state.socket, 0, 60_000) do
      {:ok, data} ->
        credentials = data |> to_string() |> String.trim()

        if credentials == "*" do
          send_response(state.socket, "501 Authentication cancelled")
          {:continue, state}
        else
          authenticate_plain(credentials, state)
        end

      {:error, _} ->
        send_response(state.socket, "535 Authentication failed")
        {:continue, state}
    end
  end

  defp handle_auth_plain(credentials, state) do
    if credentials == "*" do
      send_response(state.socket, "501 Authentication cancelled")
      {:continue, state}
    else
      authenticate_plain(credentials, state)
    end
  end

  defp authenticate_plain(credentials, state) do
    case decode_auth_plain(credentials) do
      {:ok, username, password} ->
        authenticate_user(username, password, state)

      {:error, _} ->
        send_response(state.socket, "535 Authentication failed")
        {:continue, state}
    end
  end

  defp handle_auth_login_flow(state) do
    # Receive username
    case :gen_tcp.recv(state.socket, 0, 60_000) do
      {:ok, username_data} ->
        case decode_base64_line(username_data) do
          {:ok, "*"} ->
            send_response(state.socket, "501 Authentication cancelled")
            {:continue, state}

          {:ok, username} ->
            send_response(state.socket, "334 UGFzc3dvcmQ6")
            handle_auth_login_password(username, state)

          :error ->
            send_response(state.socket, "535 Authentication failed")
            {:continue, state}
        end

      {:error, _} ->
        send_response(state.socket, "535 Authentication failed")
        {:continue, state}
    end
  end

  defp handle_auth_login_password(username, state) do
    # Receive password
    case :gen_tcp.recv(state.socket, 0, 60_000) do
      {:ok, password_data} ->
        case decode_base64_line(password_data) do
          {:ok, "*"} ->
            send_response(state.socket, "501 Authentication cancelled")
            {:continue, state}

          {:ok, password} ->
            authenticate_user(username, password, state)

          :error ->
            send_response(state.socket, "535 Authentication failed")
            {:continue, state}
        end

      {:error, _} ->
        send_response(state.socket, "535 Authentication failed")
        {:continue, state}
    end
  end

  defp decode_auth_plain(credentials) do
    try do
      decoded = Base.decode64!(credentials)
      # PLAIN format: \0username\0password or username\0username\0password
      case String.split(decoded, "\0") do
        ["", username, password] ->
          {:ok, username, password}

        [_authzid, username, password] ->
          {:ok, username, password}

        _ ->
          {:error, :invalid_format}
      end
    rescue
      _ -> {:error, :decode_failed}
    end
  end

  defp decode_base64_line(data) do
    line = data |> to_string() |> String.trim()

    if line == "*" do
      {:ok, "*"}
    else
      case Base.decode64(line) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> :error
      end
    end
  end

  defp authenticate_user(username, password, state) do
    # Use client IP from state for rate limiting (from PROXY protocol)
    ip_string = state.client_ip

    case check_auth_rate_limits(ip_string, username) do
      :ok ->
        case do_authenticate(username, password) do
          {:ok, user} ->
            Elektrine.SMTP.RateLimiter.clear_attempts(ip_string)
            MailAuthRateLimiter.clear_attempts(:smtp, username)
            MailTelemetry.auth(:smtp, :success, %{source: :auth})
            send_response(state.socket, "235 Authentication successful")

            {:continue,
             %{state | authenticated: true, user: user, user_id: user.id, state: :authenticated}}

          {:error, reason} ->
            Elektrine.SMTP.RateLimiter.record_failure(ip_string)
            MailAuthRateLimiter.record_failure(:smtp, username)
            maybe_alert_auth_failure_pressure(ip_string, username)

            Logger.warning(
              "SMTP login failed: user=#{redact_identifier(username)} ip=#{ip_string}"
            )

            MailTelemetry.auth(:smtp, :failure, %{reason: reason, source: :auth})
            send_response(state.socket, "535 Authentication failed")
            {:continue, state}
        end

      {:error, {:ip, :rate_limited}} ->
        Logger.warning(
          "SMTP rate limited by IP: user=#{redact_identifier(username)} ip=#{ip_string}"
        )

        MailTelemetry.auth(:smtp, :rate_limited, %{ratelimit: :ip, source: :auth})
        send_response(state.socket, "421 Too many failed attempts")
        :timer.sleep(1000)
        {:quit, state}

      {:error, {:ip, :blocked}} ->
        Logger.warning("SMTP blocked IP: user=#{redact_identifier(username)} ip=#{ip_string}")

        MailTelemetry.auth(:smtp, :rate_limited, %{ratelimit: :ip_blocked, source: :auth})
        send_response(state.socket, "421 IP temporarily blocked")
        {:quit, state}

      {:error, {:account, :rate_limited}} ->
        Logger.warning(
          "SMTP rate limited by account key: user=#{redact_identifier(username)} ip=#{ip_string}"
        )

        MailTelemetry.auth(:smtp, :rate_limited, %{ratelimit: :account, source: :auth})
        send_response(state.socket, "421 Too many failed attempts")
        :timer.sleep(1000)
        {:quit, state}

      {:error, {:account, :blocked}} ->
        Logger.warning(
          "SMTP blocked account key: user=#{redact_identifier(username)} ip=#{ip_string}"
        )

        MailTelemetry.auth(:smtp, :rate_limited, %{ratelimit: :account_blocked, source: :auth})
        send_response(state.socket, "421 Account temporarily blocked")
        {:quit, state}
    end
  end

  defp check_auth_rate_limits(ip_string, username) do
    case Elektrine.SMTP.RateLimiter.check_attempt(ip_string) do
      {:ok, _attempts_left} ->
        case MailAuthRateLimiter.check_attempt(:smtp, username) do
          {:ok, _remaining} -> :ok
          {:error, reason} -> {:error, {:account, reason}}
        end

      {:error, reason} ->
        {:error, {:ip, reason}}
    end
  end

  defp maybe_alert_auth_failure_pressure(ip_string, username) do
    ip_failures =
      Elektrine.SMTP.RateLimiter.get_status(ip_string)
      |> get_in([:attempts, 60, :count]) || 0

    account_failures = MailAuthRateLimiter.failure_count(:smtp, username)

    if ip_failures >= 2 or account_failures >= 3 do
      Logger.warning(
        "SMTP auth failure spike: ip=#{ip_string} ip_failures=#{ip_failures} account_failures=#{account_failures}"
      )
    end
  end

  defp redact_identifier(nil), do: "<nil>"

  defp redact_identifier(identifier) do
    text = identifier |> to_string() |> String.trim()

    if String.contains?(text, "@") do
      [local, domain] = String.split(text, "@", parts: 2)
      "#{String.slice(local, 0, 2)}***@#{domain}"
    else
      "#{String.slice(text, 0, 2)}***"
    end
  end

  # Optimized auth: queries user only ONCE (user is returned even on app password failure)
  defp do_authenticate(username, password) do
    case Elektrine.Accounts.authenticate_with_app_password(username, password) do
      {:ok, user} ->
        {:ok, user}

      {:error, {:invalid_token, user}} ->
        # App password failed but we have the user - try regular password
        if has_2fa_enabled?(user) do
          {:error, :requires_app_password}
        else
          case Elektrine.Accounts.verify_user_password(user, password) do
            {:ok, _user} -> {:ok, user}
            {:error, _} -> {:error, :authentication_failed}
          end
        end

      {:error, :user_not_found} ->
        {:error, :authentication_failed}
    end
  end

  defp has_2fa_enabled?(user) do
    user.two_factor_enabled == true
  end

  defp handle_mail(args, state) when state.authenticated do
    case parse_mail_from(args) do
      {:ok, from} ->
        # Verify user owns this address
        case verify_from_address(from, state.user_id) do
          :ok ->
            send_response(state.socket, "250 OK")
            {:continue, %{state | from: from, to: [], data: "", state: :mail}}

          {:error, _} ->
            send_response(state.socket, "550 Not authorized to send from this address")
            {:continue, state}
        end

      {:error, _} ->
        send_response(state.socket, "501 Syntax error in parameters")
        {:continue, state}
    end
  end

  defp handle_mail(_args, state) do
    send_response(state.socket, "530 Authentication required")
    {:continue, state}
  end

  defp parse_mail_from(args) do
    # Parse MAIL FROM:<email@domain.com>
    case Regex.run(~r/FROM:\s*<?([^>]+)>?/i, args || "") do
      [_, email] -> {:ok, String.trim(email)}
      _ -> {:error, :invalid_format}
    end
  end

  defp verify_from_address(from, user_id) do
    case Elektrine.Email.verify_email_ownership(from, user_id) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :unauthorized}
    end
  end

  defp handle_rcpt(args, state) when state.state == :mail do
    # SECURITY: Limit number of recipients to prevent DOS
    if length(state.to) >= @max_recipients do
      send_response(state.socket, "452 Too many recipients")
      {:continue, state}
    else
      case parse_rcpt_to(args) do
        {:ok, to} ->
          send_response(state.socket, "250 OK")
          {:continue, %{state | to: [to | state.to], state: :rcpt}}

        {:error, _} ->
          send_response(state.socket, "501 Syntax error in parameters")
          {:continue, state}
      end
    end
  end

  defp handle_rcpt(args, state) when state.state == :rcpt do
    # SECURITY: Limit number of recipients to prevent DOS
    if length(state.to) >= @max_recipients do
      send_response(state.socket, "452 Too many recipients")
      {:continue, state}
    else
      case parse_rcpt_to(args) do
        {:ok, to} ->
          send_response(state.socket, "250 OK")
          {:continue, %{state | to: [to | state.to]}}

        {:error, _} ->
          send_response(state.socket, "501 Syntax error in parameters")
          {:continue, state}
      end
    end
  end

  defp handle_rcpt(_args, state) do
    send_response(state.socket, "503 Bad sequence of commands")
    {:continue, state}
  end

  defp parse_rcpt_to(args) when is_binary(args) do
    # Parse RCPT TO:<email@domain.com>
    case Regex.run(~r/TO:\s*<?([^>]+)>?/i, args) do
      [_, email] -> {:ok, String.trim(email)}
      _ -> {:error, :invalid_format}
    end
  end

  defp handle_data(state) when state.state == :rcpt and state.to != [] do
    send_response(state.socket, "354 End data with <CR><LF>.<CR><LF>")

    # Give a tiny delay to ensure 354 response is flushed
    Process.sleep(10)

    # Switch to binary mode for faster data collection
    :inet.setopts(state.socket, [{:packet, :raw}, {:active, false}])

    result = collect_data_binary(state.socket)

    # Ensure we're back in line mode for next commands
    :inet.setopts(state.socket, [{:packet, :line}, {:active, false}])

    case result do
      {:ok, data} ->
        # Send the email using Email.Sender
        send_result = send_email(state, data)

        case send_result do
          {:ok, _message} ->
            send_response(state.socket, "250 OK: Message accepted")
            {:continue, %{state | from: nil, to: [], data: "", state: :authenticated}}

          {:error, :rate_limit_exceeded} ->
            Logger.warning("SMTP: Rate limit exceeded")
            send_response(state.socket, "450 Rate limit exceeded - try again later")
            {:continue, %{state | from: nil, to: [], data: "", state: :authenticated}}

          {:error, :recipient_limit_exceeded} ->
            Logger.warning("SMTP: Unique recipient limit exceeded")

            send_response(
              state.socket,
              "450 Too many unique recipients today - try again tomorrow"
            )

            {:continue, %{state | from: nil, to: [], data: "", state: :authenticated}}

          {:error, :ip_rate_limited} ->
            Logger.warning("SMTP: IP rate limited")
            send_response(state.socket, "450 Too many emails from this IP - try again later")
            {:continue, %{state | from: nil, to: [], data: "", state: :authenticated}}

          {:error, reason} ->
            Logger.error("SMTP: Failed to send email: #{inspect(reason)}")
            send_response(state.socket, "550 Message rejected")
            {:continue, %{state | from: nil, to: [], data: "", state: :authenticated}}
        end

      {:error, :message_too_large} ->
        send_response(state.socket, "552 Message exceeds maximum size")
        {:continue, %{state | from: nil, to: [], data: "", state: :authenticated}}

      {:error, _} ->
        send_response(state.socket, "451 Error processing message")
        {:continue, state}
    end
  end

  defp handle_data(state) do
    Logger.warning(
      "SMTP handle_data rejected: state=#{inspect(state.state)}, to_count=#{length(state.to)}"
    )

    send_response(state.socket, "503 Bad sequence of commands")
    {:continue, state}
  end

  # Fast binary mode data collection for large emails with attachments
  defp collect_data_binary(socket, acc \\ <<>>, size_so_far \\ 0) do
    # SECURITY: Enforce maximum data size
    if size_so_far > @max_data_size do
      Logger.warning("SMTP DATA rejected: size #{size_so_far} exceeds limit #{@max_data_size}")
      {:error, :message_too_large}
    else
      # Use 0 to read whatever is available (don't wait for specific chunk size)
      case :gen_tcp.recv(socket, 0, 30_000) do
        {:ok, chunk_raw} ->
          # Convert charlist to binary if needed
          chunk = if is_list(chunk_raw), do: :erlang.list_to_binary(chunk_raw), else: chunk_raw
          new_acc = acc <> chunk
          new_size = size_so_far + byte_size(chunk)

          # Check for end marker: \r\n.\r\n
          if String.contains?(new_acc, "\r\n.\r\n") do
            # Found end marker, extract data before it
            [data, _rest] = String.split(new_acc, "\r\n.\r\n", parts: 2)

            # Remove dot-stuffing (lines starting with .. become .)
            cleaned_data = String.replace(data, ~r/\r\n\.\./m, "\r\n.")

            {:ok, cleaned_data}
          else
            # Keep collecting
            collect_data_binary(socket, new_acc, new_size)
          end

        {:error, :closed} ->
          {:error, :closed}

        {:error, reason} ->
          Logger.error("SMTP data collection error: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp send_email(state, data) do
    # Check IP-based rate limit first (anti-bot)
    case Elektrine.SMTP.SendRateLimiter.check_send_limit(state.client_ip) do
      {:error, :ip_rate_limited} ->
        Logger.warning("SMTP: IP rate limited for #{state.client_ip}")
        {:error, :ip_rate_limited}

      {:ok, :allowed} ->
        # Don't parse email data - just pass raw email to sender
        # The Haraka API or receiver will handle MIME parsing
        params = %{
          from: state.from,
          to: Enum.reverse(state.to) |> Enum.join(", "),
          # Will be parsed from raw_email
          subject: "(SMTP raw message)",
          # Pass the entire raw email data for proper MIME handling
          raw_email: data
        }

        result = Elektrine.Email.Sender.send_email(state.user_id, params)

        # Record the send for IP rate limiting on success
        if match?({:ok, _}, result) do
          Elektrine.SMTP.SendRateLimiter.record_send(state.client_ip)
        end

        result
    end
  end

  defp handle_rset(state) do
    send_response(state.socket, "250 OK")
    {:continue, %{state | from: nil, to: [], data: "", state: :authenticated}}
  end

  defp handle_noop(state) do
    send_response(state.socket, "250 OK")
    {:continue, state}
  end

  defp handle_quit(state) do
    send_response(state.socket, "221 Bye")
    {:quit, state}
  end

  defp handle_unknown(cmd, state) do
    send_response(state.socket, "500 Command not recognized: #{cmd}")
    {:continue, state}
  end

  # Connection limit enforcement (DOS protection)
  defp can_accept_connection?(ip) do
    try do
      # Check total connections
      [{:total, total}] = :ets.lookup(:smtp_active_connections, :total)

      if total >= @max_connections do
        false
      else
        # Check per-IP limit
        ip_count =
          case :ets.lookup(:smtp_active_connections, ip) do
            [{^ip, count}] -> count
            [] -> 0
          end

        ip_count < @max_connections_per_ip
      end
    rescue
      # Table doesn't exist, refuse connection
      ArgumentError -> false
    end
  end

  defp increment_connection_count(ip) do
    try do
      # Increment total
      :ets.update_counter(:smtp_active_connections, :total, {2, 1})

      # Increment per-IP
      case :ets.lookup(:smtp_active_connections, ip) do
        [{^ip, count}] ->
          :ets.insert(:smtp_active_connections, {ip, count + 1})

        [] ->
          :ets.insert(:smtp_active_connections, {ip, 1})
      end

      emit_session_count(ip)
    rescue
      # Table doesn't exist
      ArgumentError -> :ok
    end
  end

  defp decrement_connection_count(ip) do
    try do
      # Decrement total
      :ets.update_counter(:smtp_active_connections, :total, {2, -1})

      # Decrement per-IP
      case :ets.lookup(:smtp_active_connections, ip) do
        [{^ip, count}] when count > 1 ->
          :ets.insert(:smtp_active_connections, {ip, count - 1})

        [{^ip, 1}] ->
          :ets.delete(:smtp_active_connections, ip)

        [] ->
          Logger.warning(
            "Attempted to decrement SMTP connection count for #{ip} but no entry found"
          )
      end

      emit_session_count(ip)
    rescue
      ArgumentError ->
        # Table doesn't exist (server was restarted)
        :ok
    end
  end

  defp emit_session_count(ip) do
    total =
      case :ets.lookup(:smtp_active_connections, :total) do
        [{:total, count}] -> count
        [] -> 0
      end

    ip_count =
      case :ets.lookup(:smtp_active_connections, ip) do
        [{^ip, count}] -> count
        [] -> 0
      end

    MailTelemetry.sessions(:smtp, total, ip_count)
    maybe_alert_session_pressure(total, ip_count, ip)
  end

  defp maybe_alert_session_pressure(total, ip_count, ip) do
    total_threshold = max(1, div(@max_connections * 8, 10))
    ip_threshold = max(1, div(@max_connections_per_ip * 8, 10))

    cond do
      total >= total_threshold ->
        Logger.warning(
          "SMTP connection pressure: total=#{total}/#{@max_connections} ip=#{ip} ip_sessions=#{ip_count}/#{@max_connections_per_ip}"
        )

      ip_count >= ip_threshold ->
        Logger.warning(
          "SMTP per-IP session pressure: ip=#{ip} sessions=#{ip_count}/#{@max_connections_per_ip} total=#{total}/#{@max_connections}"
        )

      true ->
        :ok
    end
  end

  defp command_outcome({:continue, _state}), do: :ok
  defp command_outcome({:quit, _state}), do: :quit
  defp command_outcome(_), do: :error

  defp maybe_alert_slow_command(command_name, duration_us, ip) do
    if duration_us >= @slow_command_threshold_us do
      duration_ms = Float.round(duration_us / 1_000, 1)

      Logger.warning(
        "Slow SMTP command: command=#{command_name} duration_ms=#{duration_ms} ip=#{ip}"
      )
    end
  end

  # Normalizes IPv6 addresses to /64 subnet to prevent brute-force via address rotation
  defp normalize_ipv6_subnet(ip_string) do
    if String.contains?(ip_string, ":") do
      # IPv6 - normalize to /64 subnet (first 4 hextets)
      hextets = String.split(ip_string, ":")

      if Enum.any?(hextets, &(&1 == "")) do
        # Compressed notation (::) - expand it
        parts_before = Enum.take_while(hextets, &(&1 != ""))
        parts_after = hextets |> Enum.drop_while(&(&1 != "")) |> Enum.drop(1)
        zeros_needed = 8 - length(parts_before) - length(parts_after)
        expanded = parts_before ++ List.duplicate("0", zeros_needed) ++ parts_after
        Enum.take(expanded, 4) |> Enum.join(":") |> Kernel.<>("::/64")
      else
        # Full notation - take first 4 hextets
        Enum.take(hextets, 4) |> Enum.join(":") |> Kernel.<>("::/64")
      end
    else
      # IPv4 - return as-is
      ip_string
    end
  end

  defp send_response(socket, message) do
    :gen_tcp.send(socket, "#{message}\r\n")
  end
end
