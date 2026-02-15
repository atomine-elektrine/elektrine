defmodule Elektrine.POP3.Server do
  @moduledoc """
  POP3 server implementation for Elektrine email system.
  Provides POP3 protocol support for email clients to retrieve messages.
  """

  use GenServer
  require Logger
  alias Elektrine.Accounts
  alias Elektrine.Constants
  alias Elektrine.Email
  alias Elektrine.Email.AttachmentStorage
  alias Elektrine.Mail.Telemetry, as: MailTelemetry
  alias Elektrine.MailAuth.RateLimiter, as: MailAuthRateLimiter
  alias Elektrine.POP3.RateLimiter
  alias Elektrine.ProxyProtocol

  # Security limits
  @max_connections Constants.pop3_max_connections()
  @max_connections_per_ip Constants.pop3_max_connections_per_ip()
  @slow_command_threshold_us 500_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    port = Keyword.get(opts, :port, Application.get_env(:elektrine, :pop3_port, 2110))

    Logger.info("Attempting to start POP3 server on port #{port}")

    case :gen_tcp.listen(port, [
           {:active, false},
           {:packet, :line},
           # Security: limit command line length
           {:packet_size, 8192},
           {:reuseaddr, true},
           {:ip, {0, 0, 0, 0}},
           {:backlog, 100},
           {:keepalive, true},
           {:send_timeout, Constants.pop3_send_timeout_ms()},
           {:send_timeout_close, true}
         ]) do
      {:ok, socket} ->
        Logger.info("POP3 server successfully listening on port #{port}")
        # Create ETS table for connection tracking
        :ets.new(:pop3_active_connections, [:set, :public, :named_table])
        :ets.insert(:pop3_active_connections, {:total, 0})
        spawn_link(fn -> accept_loop(socket) end)
        {:ok, %{socket: socket, port: port, connections: 0}}

      {:error, :eaddrinuse} ->
        Logger.error("POP3 server failed: Port #{port} is already in use")
        # Don't crash the supervisor - just log the error
        {:ok, %{socket: nil, port: port, connections: 0, error: :port_in_use}}

      {:error, reason} ->
        Logger.error("Failed to start POP3 server on port #{port}: #{inspect(reason)}")
        # Don't crash the supervisor - just log the error
        {:ok, %{socket: nil, port: port, connections: 0, error: reason}}
    end
  end

  defp accept_loop(socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        handle_accepted_client(client)

        accept_loop(socket)

      {:error, reason} ->
        Logger.error("Accept failed: #{inspect(reason)}")
        :timer.sleep(1000)
        accept_loop(socket)
    end
  end

  defp handle_accepted_client(client) do
    {client_ip, initial_data} = parse_client_ip_and_data(client)
    maybe_start_client_session(client, client_ip, initial_data)
  end

  defp parse_client_ip_and_data(client) do
    case ProxyProtocol.parse_client_ip(client) do
      {:ok, ip, data} ->
        {normalize_ipv6_subnet(ip), data}

      {:error, _reason} ->
        fallback_client_ip(client)
    end
  end

  defp fallback_client_ip(client) do
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

  defp maybe_start_client_session(_client, nil, _initial_data), do: :ok

  defp maybe_start_client_session(client, client_ip, initial_data) do
    if can_accept_connection?(client_ip) do
      configure_client_socket(client)
      increment_connection_count(client_ip)
      spawn_client_handler(client, client_ip, initial_data)
    else
      reject_client_connection(client, client_ip)
    end
  end

  defp configure_client_socket(client) do
    :inet.setopts(client, [
      {:keepalive, true},
      {:nodelay, true},
      {:send_timeout, Constants.pop3_send_timeout_ms()}
    ])
  end

  defp spawn_client_handler(client, client_ip, initial_data) do
    spawn(fn ->
      try do
        handle_client(client, client_ip, initial_data)
      after
        decrement_connection_count(client_ip)
      end
    end)
  end

  defp reject_client_connection(client, client_ip) do
    Logger.warning("POP3 connection rejected from #{client_ip}: connection limit exceeded")
    send_response(client, "-ERR Too many connections from your IP address")
    :gen_tcp.close(client)
  end

  defp handle_client(socket, client_ip, initial_data) do
    send_response(socket, "+OK Elektrine POP3 server ready")

    state = %{
      socket: socket,
      client_ip: client_ip,
      authenticated: false,
      user: nil,
      mailbox: nil,
      messages: [],
      message_size_cache: %{},
      deleted_messages: MapSet.new(),
      transaction_state: :authorization,
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
        # POP3 timeout is typically 10 minutes (600000 ms)
        case :gen_tcp.recv(state.socket, 0, 600_000) do
          {:ok, data} ->
            {data, state}

          {:error, :timeout} ->
            # Send timeout message and close
            send_response(state.socket, "-ERR Connection timeout")
            :gen_tcp.close(state.socket)
            {nil, state}

          {:error, :closed} ->
            :gen_tcp.close(state.socket)
            {nil, state}

          {:error, reason} ->
            Logger.error("POP3 receive error: #{inspect(reason)}")
            :gen_tcp.close(state.socket)
            {nil, state}
        end
      end

    if command_data do
      # Convert charlist to string if needed
      command = command_data |> to_string() |> String.trim()

      case handle_command(command, updated_state) do
        {:continue, new_state} ->
          client_loop(new_state)

        {:quit, new_state} ->
          handle_quit(new_state)
      end
    end
  end

  defp handle_command(command, state) do
    started_at = System.monotonic_time(:microsecond)

    {command_name, result} =
      case String.split(command, " ", parts: 2) do
        [cmd | args] ->
          normalized_cmd = String.upcase(cmd)
          parsed_args = if args == [], do: nil, else: List.first(args)

          handled =
            case state.transaction_state do
              :authorization ->
                handle_auth_command(normalized_cmd, parsed_args, state)

              :transaction ->
                handle_transaction_command(normalized_cmd, parsed_args, state)

              _ ->
                send_response(state.socket, "-ERR Unknown state")
                {:continue, state}
            end

          {normalized_cmd, handled}

        _ ->
          send_response(state.socket, "-ERR Invalid command")
          {"INVALID", {:continue, state}}
      end

    duration_us = System.monotonic_time(:microsecond) - started_at
    outcome = command_outcome(result)
    MailTelemetry.command(:pop3, command_name, duration_us, outcome)
    maybe_alert_slow_command(command_name, duration_us, state.client_ip)

    result
  end

  defp handle_auth_command("USER", nil, state) do
    send_response(state.socket, "-ERR Username required")
    {:continue, state}
  end

  defp handle_auth_command("USER", username, state) do
    send_response(state.socket, "+OK User accepted")
    {:continue, %{state | user: username}}
  end

  defp handle_auth_command("PASS", nil, state) do
    send_response(state.socket, "-ERR Password required")
    {:continue, state}
  end

  defp handle_auth_command("PASS", password, state) when is_binary(state.user) do
    # Use client IP from state for rate limiting (from PROXY protocol)
    ip_string = state.client_ip

    case check_auth_rate_limits(ip_string, state.user) do
      :ok ->
        case authenticate_user(state.user, password) do
          {:ok, _user, mailbox} ->
            RateLimiter.clear_attempts(ip_string)
            MailAuthRateLimiter.clear_attempts(:pop3, state.user)
            MailTelemetry.auth(:pop3, :success, %{source: :pass})
            messages = load_messages(mailbox)
            message_size_cache = build_size_cache(messages)
            send_response(state.socket, "+OK Logged in")

            {:continue,
             %{
               state
               | authenticated: true,
                 mailbox: mailbox,
                 messages: messages,
                 message_size_cache: message_size_cache,
                 transaction_state: :transaction
             }}

          {:error, reason} ->
            RateLimiter.record_failure(ip_string)
            MailAuthRateLimiter.record_failure(:pop3, state.user)
            maybe_alert_auth_failure_pressure(ip_string, state.user)

            Logger.warning(
              "POP3 login failed: user=#{redact_identifier(state.user)} ip=#{ip_string}"
            )

            MailTelemetry.auth(:pop3, :failure, %{reason: reason, source: :pass})
            send_response(state.socket, "-ERR Authentication failed")
            {:continue, %{state | user: nil}}
        end

      {:error, {:ip, :rate_limited}} ->
        Logger.warning(
          "POP3 rate limited by IP: user=#{redact_identifier(state.user)} ip=#{ip_string}"
        )

        MailTelemetry.auth(:pop3, :rate_limited, %{ratelimit: :ip, source: :pass})
        send_response(state.socket, "-ERR Too many failed attempts. Try again later.")
        :timer.sleep(1000)
        {:quit, state}

      {:error, {:ip, :blocked}} ->
        Logger.warning("POP3 blocked IP: user=#{redact_identifier(state.user)} ip=#{ip_string}")

        MailTelemetry.auth(:pop3, :rate_limited, %{ratelimit: :ip_blocked, source: :pass})
        send_response(state.socket, "-ERR IP temporarily blocked due to excessive failures")
        {:quit, state}

      {:error, {:account, :rate_limited}} ->
        Logger.warning(
          "POP3 rate limited by account key: user=#{redact_identifier(state.user)} ip=#{ip_string}"
        )

        MailTelemetry.auth(:pop3, :rate_limited, %{ratelimit: :account, source: :pass})
        send_response(state.socket, "-ERR Too many failed attempts. Try again later.")
        :timer.sleep(1000)
        {:quit, state}

      {:error, {:account, :blocked}} ->
        Logger.warning(
          "POP3 blocked account key: user=#{redact_identifier(state.user)} ip=#{ip_string}"
        )

        MailTelemetry.auth(:pop3, :rate_limited, %{ratelimit: :account_blocked, source: :pass})
        send_response(state.socket, "-ERR Account temporarily blocked due to excessive failures")
        {:quit, state}
    end
  end

  defp handle_auth_command("PASS", _password, state) do
    send_response(state.socket, "-ERR Send USER first")
    {:continue, state}
  end

  defp handle_auth_command("QUIT", _args, state) do
    send_response(state.socket, "+OK Goodbye")
    {:quit, state}
  end

  defp handle_auth_command("CAPA", _args, state) do
    send_response(state.socket, "+OK Capability list follows")
    send_response(state.socket, "USER")
    send_response(state.socket, "UIDL")
    send_response(state.socket, "TOP")
    send_response(state.socket, ".")
    {:continue, state}
  end

  defp handle_auth_command(_cmd, _args, state) do
    send_response(state.socket, "-ERR Command not recognized")
    {:continue, state}
  end

  defp handle_transaction_command("STAT", _args, state) do
    {count, size} = calculate_stats(state)
    send_response(state.socket, "+OK #{count} #{size}")
    {:continue, state}
  end

  defp handle_transaction_command("LIST", nil, state) do
    send_response(state.socket, "+OK Message list follows")

    state.messages
    |> Enum.with_index(1)
    |> Enum.reject(fn {_msg, idx} -> MapSet.member?(state.deleted_messages, idx) end)
    |> Enum.each(fn {_msg, idx} ->
      size = get_message_size(state, idx)
      send_response(state.socket, "#{idx} #{size}")
    end)

    send_response(state.socket, ".")
    {:continue, state}
  end

  defp handle_transaction_command("LIST", msg_num, state) do
    case Integer.parse(msg_num) do
      {num, ""} when num > 0 and num <= length(state.messages) ->
        if MapSet.member?(state.deleted_messages, num) do
          send_response(state.socket, "-ERR Message deleted")
        else
          size = get_message_size(state, num)
          send_response(state.socket, "+OK #{num} #{size}")
        end

      _ ->
        send_response(state.socket, "-ERR Invalid message number")
    end

    {:continue, state}
  end

  defp handle_transaction_command("RETR", nil, state) do
    send_response(state.socket, "-ERR Message number required")
    {:continue, state}
  end

  defp handle_transaction_command("RETR", msg_num, state) do
    case Integer.parse(msg_num) do
      {num, ""} when num > 0 and num <= length(state.messages) ->
        if MapSet.member?(state.deleted_messages, num) do
          send_response(state.socket, "-ERR Message deleted")
          {:continue, state}
        else
          msg = Enum.at(state.messages, num - 1)
          content = format_message_for_pop3(msg)
          size = byte_size(content)
          updated_cache = Map.put(state.message_size_cache, num, size)

          send_response(state.socket, "+OK #{size} octets")
          send_raw(state.socket, content)
          send_response(state.socket, ".")
          {:continue, %{state | message_size_cache: updated_cache}}
        end

      _ ->
        send_response(state.socket, "-ERR Invalid message number")
        {:continue, state}
    end
  end

  defp handle_transaction_command("DELE", nil, state) do
    send_response(state.socket, "-ERR Message number required")
    {:continue, state}
  end

  defp handle_transaction_command("DELE", msg_num, state) do
    case Integer.parse(msg_num) do
      {num, ""} when num > 0 and num <= length(state.messages) ->
        if MapSet.member?(state.deleted_messages, num) do
          send_response(state.socket, "-ERR Message already deleted")
          {:continue, state}
        else
          new_deleted = MapSet.put(state.deleted_messages, num)
          send_response(state.socket, "+OK Message deleted")
          {:continue, %{state | deleted_messages: new_deleted}}
        end

      _ ->
        send_response(state.socket, "-ERR Invalid message number")
        {:continue, state}
    end
  end

  defp handle_transaction_command("NOOP", _args, state) do
    send_response(state.socket, "+OK")
    {:continue, state}
  end

  defp handle_transaction_command("RSET", _args, state) do
    send_response(state.socket, "+OK")
    {:continue, %{state | deleted_messages: MapSet.new()}}
  end

  defp handle_transaction_command("TOP", args, state) do
    case parse_top_args(args, length(state.messages)) do
      {:ok, num, line_count} ->
        send_top_message_response(state, num, line_count)

      :error ->
        send_response(state.socket, "-ERR Invalid arguments")
    end

    {:continue, state}
  end

  defp handle_transaction_command("UIDL", nil, state) do
    send_response(state.socket, "+OK Unique-ID listing follows")

    state.messages
    |> Enum.with_index(1)
    |> Enum.reject(fn {_msg, idx} -> MapSet.member?(state.deleted_messages, idx) end)
    |> Enum.each(fn {msg, idx} ->
      send_response(state.socket, "#{idx} #{msg.id}")
    end)

    send_response(state.socket, ".")
    {:continue, state}
  end

  defp handle_transaction_command("UIDL", msg_num, state) do
    case Integer.parse(msg_num) do
      {num, ""} when num > 0 and num <= length(state.messages) ->
        if MapSet.member?(state.deleted_messages, num) do
          send_response(state.socket, "-ERR Message deleted")
        else
          msg = Enum.at(state.messages, num - 1)
          send_response(state.socket, "+OK #{num} #{msg.id}")
        end

      _ ->
        send_response(state.socket, "-ERR Invalid message number")
    end

    {:continue, state}
  end

  defp handle_transaction_command("QUIT", _args, state) do
    send_response(state.socket, "+OK Goodbye")
    {:quit, state}
  end

  defp handle_transaction_command("CAPA", _args, state) do
    send_response(state.socket, "+OK Capability list follows")
    send_response(state.socket, "USER")
    send_response(state.socket, "UIDL")
    send_response(state.socket, "TOP")
    send_response(state.socket, ".")
    {:continue, state}
  end

  defp handle_transaction_command(_cmd, _args, state) do
    send_response(state.socket, "-ERR Command not recognized")
    {:continue, state}
  end

  defp parse_top_args(args, message_count) do
    case String.split(args || "", " ") do
      [msg_num, lines] ->
        case {Integer.parse(msg_num), Integer.parse(lines)} do
          {{num, ""}, {line_count, ""}} when num > 0 and num <= message_count ->
            {:ok, num, line_count}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp send_top_message_response(state, num, line_count) do
    if MapSet.member?(state.deleted_messages, num) do
      send_response(state.socket, "-ERR Message deleted")
    else
      msg = Enum.at(state.messages, num - 1)
      content = format_message_top(msg, line_count)
      send_response(state.socket, "+OK")
      send_raw(state.socket, content)
      send_response(state.socket, ".")
    end
  end

  defp handle_quit(state) do
    if state.authenticated and MapSet.size(state.deleted_messages) > 0 do
      Enum.each(state.deleted_messages, fn idx ->
        msg = Enum.at(state.messages, idx - 1)
        mark_message_as_deleted(msg)
      end)
    end

    :gen_tcp.close(state.socket)
  end

  defp check_auth_rate_limits(ip_string, username) do
    case RateLimiter.check_attempt(ip_string) do
      {:ok, _attempts_left} ->
        case MailAuthRateLimiter.check_attempt(:pop3, username) do
          {:ok, _remaining} -> :ok
          {:error, reason} -> {:error, {:account, reason}}
        end

      {:error, reason} ->
        {:error, {:ip, reason}}
    end
  end

  defp maybe_alert_auth_failure_pressure(ip_string, username) do
    ip_failures = RateLimiter.get_status(ip_string) |> get_in([:attempts, 60, :count]) || 0
    account_failures = MailAuthRateLimiter.failure_count(:pop3, username)

    if ip_failures >= 4 or account_failures >= 4 do
      Logger.warning(
        "POP3 auth failure spike: ip=#{ip_string} ip_failures=#{ip_failures} account_failures=#{account_failures}"
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

  defp authenticate_user(username, password) do
    case Accounts.authenticate_with_app_password(username, password) do
      {:ok, user} ->
        finalize_successful_auth(user)

      {:error, {:invalid_token, user}} ->
        if has_2fa_enabled?(user) do
          {:error, :requires_app_password}
        else
          case Accounts.verify_user_password(user, password) do
            {:ok, _user} -> finalize_successful_auth(user)
            {:error, _reason} -> {:error, :authentication_failed}
          end
        end

      {:error, :user_not_found} ->
        {:error, :authentication_failed}
    end
  end

  defp finalize_successful_auth(user) do
    Accounts.record_pop3_access(user.id)

    case get_or_create_mailbox(user) do
      {:ok, mailbox} -> {:ok, user, mailbox}
      _ -> {:error, :mailbox_error}
    end
  end

  defp has_2fa_enabled?(user) do
    # Check if user has 2FA enabled
    user.two_factor_enabled == true
  end

  defp get_or_create_mailbox(user) do
    case Email.ensure_user_has_mailbox(user) do
      {:ok, mailbox} -> {:ok, mailbox}
      _ -> {:error, :mailbox_error}
    end
  end

  defp load_messages(mailbox) do
    Email.list_messages_for_pop3(mailbox.id)
  end

  defp calculate_stats(state) do
    active_indices =
      state.messages
      |> Enum.with_index(1)
      |> Enum.reject(fn {_msg, idx} -> MapSet.member?(state.deleted_messages, idx) end)
      |> Enum.map(fn {_msg, idx} -> idx end)

    total_size =
      Enum.reduce(active_indices, 0, fn idx, acc ->
        acc + get_message_size(state, idx)
      end)

    {length(active_indices), total_size}
  end

  defp build_size_cache(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.into(%{}, fn {message, idx} ->
      {idx, estimate_message_size(message)}
    end)
  end

  defp get_message_size(state, idx) do
    case state.message_size_cache do
      %{^idx => cached_size} ->
        cached_size

      _ ->
        case Enum.at(state.messages, idx - 1) do
          nil -> 0
          message -> estimate_message_size(message)
        end
    end
  end

  defp estimate_message_size(message) do
    has_attachments =
      message.has_attachments && message.attachments && map_size(message.attachments) > 0

    if has_attachments do
      estimate_message_size_with_attachments(message)
    else
      byte_size(build_raw_email(message))
    end
  end

  defp estimate_message_size_with_attachments(message) do
    header_size =
      byte_size(message.from || "") +
        byte_size(message.to || "") +
        byte_size(message.subject || "") +
        byte_size(message.message_id || "") +
        220

    body_size = byte_size(message.text_body || "") + byte_size(message.html_body || "")

    attachments_size =
      message.attachments
      |> Map.values()
      |> Enum.reduce(0, fn attachment, acc ->
        filename = attachment["filename"] || "attachment"
        content_type = attachment["content_type"] || "application/octet-stream"
        raw_size = parse_attachment_size(attachment)
        encoded_size = div(raw_size * 4 + 2, 3)
        part_overhead = byte_size(filename) + byte_size(content_type) + 180
        acc + encoded_size + part_overhead
      end)

    boundary_overhead = map_size(message.attachments) * 80 + 120
    header_size + body_size + attachments_size + boundary_overhead
  end

  defp parse_attachment_size(attachment) do
    case attachment["size"] do
      size when is_integer(size) and size >= 0 ->
        size

      size when is_binary(size) ->
        case Integer.parse(size) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> byte_size(attachment["data"] || "")
        end

      _ ->
        byte_size(attachment["data"] || "")
    end
  end

  defp format_message_for_pop3(message) do
    build_raw_email(message)
  end

  defp format_message_top(message, line_count) do
    content = format_message_for_pop3(message)

    lines = String.split(content, "\r\n")
    {headers, body} = Enum.split_while(lines, fn line -> line != "" end)

    body_lines = Enum.take(body, line_count + 1)

    (headers ++ body_lines)
    |> Enum.join("\r\n")
  end

  defp build_raw_email(message) do
    has_attachments =
      message.has_attachments && message.attachments && map_size(message.attachments) > 0

    if has_attachments do
      # Build multipart/mixed for messages with attachments
      build_email_with_attachments(message)
    else
      # Simple email without attachments
      build_simple_email(message)
    end
  end

  defp build_simple_email(message) do
    cond do
      # If we have both text and HTML, create multipart/alternative
      message.text_body && message.html_body ->
        boundary = generate_boundary()

        """
        From: #{message.from}
        To: #{message.to}
        Subject: #{message.subject}
        Date: #{format_date(message.inserted_at)}
        Message-ID: <#{message.message_id}>
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="#{boundary}"

        --#{boundary}
        Content-Type: text/plain; charset="UTF-8"
        Content-Transfer-Encoding: quoted-printable

        #{message.text_body}

        --#{boundary}
        Content-Type: text/html; charset="UTF-8"
        Content-Transfer-Encoding: quoted-printable

        #{message.html_body}

        --#{boundary}--
        """

      # If we only have HTML
      message.html_body ->
        """
        From: #{message.from}
        To: #{message.to}
        Subject: #{message.subject}
        Date: #{format_date(message.inserted_at)}
        Message-ID: <#{message.message_id}>
        MIME-Version: 1.0
        Content-Type: text/html; charset="UTF-8"
        Content-Transfer-Encoding: quoted-printable

        #{message.html_body}
        """

      # If we only have text (or neither)
      true ->
        """
        From: #{message.from}
        To: #{message.to}
        Subject: #{message.subject}
        Date: #{format_date(message.inserted_at)}
        Message-ID: <#{message.message_id}>
        MIME-Version: 1.0
        Content-Type: text/plain; charset="UTF-8"
        Content-Transfer-Encoding: quoted-printable

        #{message.text_body || ""}
        """
    end
  end

  defp build_email_with_attachments(message) do
    outer_boundary = generate_boundary()

    headers = build_multipart_headers(message, outer_boundary)
    body_part = build_multipart_body(message, outer_boundary)
    attachment_parts = build_attachment_parts(message.attachments, outer_boundary)

    headers <>
      "\r\n" <>
      body_part <>
      Enum.join(attachment_parts, "\r\n") <>
      "\r\n--#{outer_boundary}--\r\n"
  end

  defp build_multipart_headers(message, outer_boundary) do
    """
    From: #{message.from}
    To: #{message.to}
    Subject: #{message.subject}
    Date: #{format_date(message.inserted_at)}
    Message-ID: <#{message.message_id}>
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="#{outer_boundary}"
    """
  end

  defp build_multipart_body(message, outer_boundary) do
    if message.text_body && message.html_body do
      inner_boundary = generate_boundary()

      """
      --#{outer_boundary}
      Content-Type: multipart/alternative; boundary="#{inner_boundary}"

      --#{inner_boundary}
      Content-Type: text/plain; charset="UTF-8"
      Content-Transfer-Encoding: quoted-printable

      #{message.text_body}

      --#{inner_boundary}
      Content-Type: text/html; charset="UTF-8"
      Content-Transfer-Encoding: quoted-printable

      #{message.html_body}

      --#{inner_boundary}--
      """
    else
      content_type = if message.html_body, do: "text/html", else: "text/plain"
      body_content = message.html_body || message.text_body || ""

      """
      --#{outer_boundary}
      Content-Type: #{content_type}; charset="UTF-8"
      Content-Transfer-Encoding: quoted-printable

      #{body_content}
      """
    end
  end

  defp build_attachment_parts(attachments, outer_boundary) do
    Enum.map(attachments, fn {_key, attachment} ->
      filename = attachment["filename"] || "attachment"
      content_type = attachment["content_type"] || "application/octet-stream"
      data = attachment_data(attachment)

      """
      --#{outer_boundary}
      Content-Type: #{content_type}; name="#{filename}"
      Content-Transfer-Encoding: base64
      Content-Disposition: attachment; filename="#{filename}"

      #{data}
      """
    end)
  end

  defp attachment_data(%{"storage_type" => "s3"} = attachment) do
    case AttachmentStorage.download_attachment(attachment) do
      {:ok, content} -> Base.encode64(content)
      {:error, _} -> attachment["data"] || ""
    end
  end

  defp attachment_data(attachment), do: attachment["data"] || ""

  defp generate_boundary do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S +0000")
  end

  defp mark_message_as_deleted(message) do
    Task.start(fn ->
      Email.delete_message(message.id)
    end)
  end

  # Connection limit enforcement (DOS protection)
  defp can_accept_connection?(ip) do
    # Check total connections
    [{:total, total}] = :ets.lookup(:pop3_active_connections, :total)

    if total >= @max_connections do
      false
    else
      # Check per-IP limit
      ip_count =
        case :ets.lookup(:pop3_active_connections, ip) do
          [{^ip, count}] -> count
          [] -> 0
        end

      ip_count < @max_connections_per_ip
    end
  end

  defp increment_connection_count(ip) do
    # Increment total
    :ets.update_counter(:pop3_active_connections, :total, {2, 1})

    # Increment per-IP
    case :ets.lookup(:pop3_active_connections, ip) do
      [{^ip, count}] ->
        :ets.insert(:pop3_active_connections, {ip, count + 1})

      [] ->
        :ets.insert(:pop3_active_connections, {ip, 1})
    end

    emit_session_count(ip)
  end

  defp decrement_connection_count(ip) do
    # Decrement total
    :ets.update_counter(:pop3_active_connections, :total, {2, -1})

    # Decrement per-IP
    case :ets.lookup(:pop3_active_connections, ip) do
      [{^ip, count}] when count > 1 ->
        :ets.insert(:pop3_active_connections, {ip, count - 1})

      [{^ip, 1}] ->
        :ets.delete(:pop3_active_connections, ip)

      [] ->
        Logger.warning(
          "Attempted to decrement POP3 connection count for #{ip} but no entry found"
        )
    end

    emit_session_count(ip)
  end

  defp emit_session_count(ip) do
    total =
      case :ets.lookup(:pop3_active_connections, :total) do
        [{:total, count}] -> count
        [] -> 0
      end

    ip_count =
      case :ets.lookup(:pop3_active_connections, ip) do
        [{^ip, count}] -> count
        [] -> 0
      end

    MailTelemetry.sessions(:pop3, total, ip_count)
    maybe_alert_session_pressure(total, ip_count, ip)
  end

  defp maybe_alert_session_pressure(total, ip_count, ip) do
    total_threshold = max(1, div(@max_connections * 8, 10))
    ip_threshold = max(1, div(@max_connections_per_ip * 8, 10))

    cond do
      total >= total_threshold ->
        Logger.warning(
          "POP3 connection pressure: total=#{total}/#{@max_connections} ip=#{ip} ip_sessions=#{ip_count}/#{@max_connections_per_ip}"
        )

      ip_count >= ip_threshold ->
        Logger.warning(
          "POP3 per-IP session pressure: ip=#{ip} sessions=#{ip_count}/#{@max_connections_per_ip} total=#{total}/#{@max_connections}"
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
        "Slow POP3 command: command=#{command_name} duration_ms=#{duration_ms} ip=#{ip}"
      )
    end
  end

  defp send_response(socket, message) do
    :gen_tcp.send(socket, "#{message}\r\n")
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

  defp send_raw(socket, data) do
    data = String.replace(data, "\n.", "\n..")

    if String.ends_with?(data, "\r\n") do
      :gen_tcp.send(socket, data)
    else
      :gen_tcp.send(socket, "#{data}\r\n")
    end
  end
end
