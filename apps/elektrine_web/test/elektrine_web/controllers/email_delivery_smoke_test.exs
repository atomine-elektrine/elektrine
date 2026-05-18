defmodule ElektrineEmailWeb.EmailDeliverySmokeTest do
  use ElektrineWeb.ConnCase, async: false
  use Oban.Testing, repo: Elektrine.Repo

  import Elektrine.AccountsFixtures

  alias Atomine.Credits
  alias Elektrine.Email
  alias Elektrine.Email.ExternalDomainThrottle
  alias Elektrine.IMAP.RateLimiter, as: IMAPRateLimiter
  alias Elektrine.MailAuth.RateLimiter, as: MailAuthRateLimiter
  alias Elektrine.POP3.RateLimiter, as: POP3RateLimiter
  alias Elektrine.SMTP.RateLimiter, as: SMTPRateLimiter

  @api_key "test_haraka_api_key"
  @localhost ~c"127.0.0.1"

  setup %{conn: conn} do
    previous_haraka_api_key = System.get_env("HARAKA_API_KEY")
    previous_oban_config = Application.get_env(:elektrine, Oban)
    previous_throttle_enabled = Application.get_env(:elektrine, :email_domain_throttle_enabled)

    previous_throttle_interval =
      Application.get_env(:elektrine, :email_domain_throttle_interval_seconds)

    System.put_env("HARAKA_API_KEY", @api_key)
    Application.put_env(:elektrine, Oban, Keyword.put(previous_oban_config, :testing, :manual))
    Application.put_env(:elektrine, :email_domain_throttle_enabled, true)
    Application.put_env(:elektrine, :email_domain_throttle_interval_seconds, 3600)

    on_exit(fn ->
      restore_env("HARAKA_API_KEY", previous_haraka_api_key)
      Application.put_env(:elektrine, Oban, previous_oban_config)
      restore_app_env(:email_domain_throttle_enabled, previous_throttle_enabled)
      restore_app_env(:email_domain_throttle_interval_seconds, previous_throttle_interval)
    end)

    clear_auth_limits()
    {:ok, conn: %{conn | host: "localhost"}}
  end

  test "SMTP submit queues external delivery, provider event updates user status", %{conn: conn} do
    Oban.Testing.with_testing_mode(:manual, fn ->
      password = "ProtocolPass123!"

      user =
        user_fixture(%{
          password: password,
          password_confirmation: password
        })

      assert {:ok, _ledger_entry} = Credits.grant(user.id, :atomine_credit, 1, "test_grant")

      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
      clear_auth_limits(user.username)

      message_id = "smtp-smoke-#{System.unique_integer([:positive])}@example.com"
      subject = "SMTP delivery smoke #{System.unique_integer([:positive])}"
      recipient = "smoke-recipient@example.net"

      ExternalDomainThrottle.record("example.net")
      submit_smtp_message!(user.username, password, mailbox.email, recipient, subject, message_id)

      sent_message = wait_for_sent_message!(mailbox.id, subject)
      assert sent_message.message_id == message_id

      [delivery] = wait_for_external_deliveries!(sent_message.id)
      assert delivery.recipient == recipient
      assert delivery.status == "pending"
      assert is_binary(delivery.trace_id)

      queued_status =
        conn
        |> log_in_user(user)
        |> get(~p"/email/#{sent_message.id}/delivery_status")
        |> json_response(200)

      assert queued_status["summary"] == %{"pending" => 1}
      assert [%{"recipient" => ^recipient, "status" => "pending"}] = queued_status["deliveries"]

      provider_conn =
        build_conn()
        |> auth_haraka_conn()
        |> post(~p"/api/haraka/provider-event", %{
          "event" => "delivered",
          "trace_id" => delivery.trace_id,
          "provider_message_id" => "provider-smoke-123",
          "response_code" => "250"
        })

      assert %{"ok" => true, "delivery_id" => delivery.id, "status" => "sent"} ==
               json_response(provider_conn, 200)

      delivered_status =
        build_conn()
        |> log_in_user(user)
        |> get(~p"/email/#{sent_message.id}/delivery_status")
        |> json_response(200)

      assert delivered_status["summary"] == %{"sent" => 1}

      assert [delivery_status] = delivered_status["deliveries"]
      assert delivery_status["recipient"] == recipient
      assert delivery_status["status"] == "sent"

      assert [%{"status" => "sent", "provider_message_id" => "provider-smoke-123"}] =
               delivery_status["attempts"]
    end)
  end

  defp submit_smtp_message!(username, password, from, recipient, subject, message_id) do
    {:ok, socket} = connect_tcp(smtp_port())
    assert String.starts_with?(recv_line!(socket), "220 ")
    assert String.starts_with?(smtp_command(socket, "STARTTLS"), "220 ")
    {:ok, socket} = upgrade_socket_to_tls(socket)

    plain_cred = Base.encode64("\0#{username}\0#{password}")
    ehlo_lines = smtp_multiline_command(socket, "EHLO localhost")
    assert Enum.any?(ehlo_lines, &String.starts_with?(&1, "250-AUTH "))
    assert String.starts_with?(smtp_command(socket, "AUTH plain #{plain_cred}"), "235 ")

    message_data =
      [
        "From: #{from}",
        "To: #{recipient}",
        "Subject: #{subject}",
        "Message-ID: <#{message_id}>",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8",
        "",
        "Smoke test body"
      ]
      |> Enum.join("\r\n")

    assert String.starts_with?(smtp_command(socket, "MAIL FROM:<#{from}>"), "250 ")
    assert String.starts_with?(smtp_command(socket, "RCPT TO:<#{recipient}>"), "250 ")
    assert String.starts_with?(smtp_command(socket, "DATA"), "354 ")
    send_line!(socket, message_data)
    send_line!(socket, ".")
    assert String.starts_with?(recv_line!(socket), "250 ")
    assert String.starts_with?(smtp_command(socket, "QUIT"), "221 ")
    :ok = close_socket(socket)
  end

  defp wait_for_sent_message!(mailbox_id, subject, attempts \\ 20)

  defp wait_for_sent_message!(_mailbox_id, subject, 0),
    do: flunk("sent message not found for #{inspect(subject)}")

  defp wait_for_sent_message!(mailbox_id, subject, attempts) do
    mailbox_id
    |> Email.list_sent_messages_paginated(1, 20)
    |> Map.fetch!(:messages)
    |> Enum.find(&(&1.subject == subject))
    |> case do
      nil ->
        Process.sleep(25)
        wait_for_sent_message!(mailbox_id, subject, attempts - 1)

      message ->
        message
    end
  end

  defp wait_for_external_deliveries!(sent_message_id, attempts \\ 20)

  defp wait_for_external_deliveries!(_sent_message_id, 0),
    do: flunk("external delivery rows not found")

  defp wait_for_external_deliveries!(sent_message_id, attempts) do
    case Email.get_external_delivery_by_sent_message_id(sent_message_id) do
      [] ->
        Process.sleep(25)
        wait_for_external_deliveries!(sent_message_id, attempts - 1)

      deliveries ->
        deliveries
    end
  end

  defp auth_haraka_conn(conn) do
    conn
    |> put_req_header("x-api-key", @api_key)
    |> put_req_header("content-type", "application/json")
  end

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp clear_auth_limits(username \\ "smoke-user") do
    IMAPRateLimiter.clear_attempts("127.0.0.1")
    POP3RateLimiter.clear_attempts("127.0.0.1")
    SMTPRateLimiter.clear_attempts("127.0.0.1")
    MailAuthRateLimiter.clear_attempts(:smtp, username)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:elektrine, key)
  defp restore_app_env(key, value), do: Application.put_env(:elektrine, key, value)

  defp smtp_port, do: Application.get_env(:elektrine, :smtp_port, 2587)

  defp connect_tcp(port) do
    :gen_tcp.connect(@localhost, port, [:binary, active: false, packet: :line], 2_000)
  end

  defp recv_line!(socket, timeout \\ 4_000) do
    case socket_recv(socket, timeout) do
      {:ok, data} -> String.trim_trailing(to_string(data), "\r\n")
      {:error, reason} -> raise "Socket recv failed: #{inspect(reason)}"
    end
  end

  defp send_line!(socket, line) do
    :ok = socket_send(socket, "#{line}\r\n")
  end

  defp smtp_command(socket, command) do
    send_line!(socket, command)
    recv_line!(socket)
  end

  defp smtp_multiline_command(socket, command) do
    send_line!(socket, command)
    recv_smtp_multiline(socket, [])
  end

  defp recv_smtp_multiline(socket, acc) do
    line = recv_line!(socket)
    next_acc = [line | acc]

    if Regex.match?(~r/^\d{3}\s/, line) do
      Enum.reverse(next_acc)
    else
      recv_smtp_multiline(socket, next_acc)
    end
  end

  defp upgrade_socket_to_tls(socket) do
    with :ok <- :inet.setopts(socket, active: false, packet: :raw),
         {:ok, tls_socket} <-
           :ssl.connect(
             socket,
             [
               active: false,
               mode: :binary,
               verify: :verify_none,
               versions: [:"tlsv1.2", :"tlsv1.3"]
             ],
             5_000
           ),
         :ok <- :ssl.setopts(tls_socket, active: false, packet: :line) do
      {:ok, tls_socket}
    end
  end

  defp close_socket(socket) do
    if ssl_socket?(socket), do: :ssl.close(socket), else: :gen_tcp.close(socket)
  end

  defp socket_send(socket, data) do
    if ssl_socket?(socket), do: :ssl.send(socket, data), else: :gen_tcp.send(socket, data)
  end

  defp socket_recv(socket, timeout) do
    if ssl_socket?(socket),
      do: :ssl.recv(socket, 0, timeout),
      else: :gen_tcp.recv(socket, 0, timeout)
  end

  defp ssl_socket?(socket)
       when is_tuple(socket) and tuple_size(socket) > 0 and elem(socket, 0) == :sslsocket,
       do: true

  defp ssl_socket?(_socket), do: false
end
