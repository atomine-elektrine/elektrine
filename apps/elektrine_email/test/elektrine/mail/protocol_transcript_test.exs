defmodule Elektrine.Mail.ProtocolTranscriptTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures
  import Elektrine.EmailFixtures

  alias Elektrine.Email
  alias Elektrine.IMAP.RateLimiter, as: IMAPRateLimiter
  alias Elektrine.MailAuth.RateLimiter, as: MailAuthRateLimiter
  alias Elektrine.POP3.RateLimiter, as: POP3RateLimiter
  alias Elektrine.SMTP.RateLimiter, as: SMTPRateLimiter

  @localhost ~c"127.0.0.1"

  test "IMAP supports UID STORE + EXPUNGE sequence semantics" do
    {user, password, _mailbox} = create_user_with_messages(3)
    clear_auth_limits(:imap, user.username)

    {:ok, socket} = connect_tcp(imap_port())
    greeting = recv_line!(socket)
    assert String.starts_with?(greeting, "* OK")
    assert greeting =~ "STARTTLS"

    assert Enum.any?(
             imap_command(socket, "A0", "LOGIN #{user.username} #{password}"),
             &String.starts_with?(&1, "A0 NO STARTTLS required")
           )

    assert Enum.any?(
             imap_command(socket, "ATLS", "STARTTLS"),
             &String.starts_with?(&1, "ATLS OK")
           )

    {:ok, socket} = upgrade_socket_to_tls(socket)

    login_lines = imap_command(socket, "A1", "LOGIN #{user.username} #{password}")
    assert Enum.any?(login_lines, &String.starts_with?(&1, "A1 OK"))

    select_lines = imap_command(socket, "A2", "SELECT INBOX")
    assert Enum.any?(select_lines, &String.starts_with?(&1, "* 3 EXISTS"))
    assert Enum.any?(select_lines, &String.starts_with?(&1, "A2 OK"))

    fetch_lines = imap_command(socket, "A3", "FETCH 1:* (UID)")

    uid_pairs =
      fetch_lines
      |> Enum.map(fn line ->
        case Regex.run(~r/^\* (\d+) FETCH .*UID (\d+)/, line) do
          [_, seq, uid] -> {String.to_integer(seq), String.to_integer(uid)}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&elem(&1, 0))

    assert length(uid_pairs) >= 2

    [{_seq1, uid1}, {_seq2, uid2} | _] = uid_pairs

    store_lines =
      imap_command(socket, "A4", "UID STORE #{uid1},#{uid2} +FLAGS.SILENT (\\Deleted)")

    refute Enum.any?(store_lines, &String.contains?(&1, " FETCH "))
    assert Enum.any?(store_lines, &String.starts_with?(&1, "A4 OK"))

    expunge_lines = imap_command(socket, "A5", "EXPUNGE")
    expunge_events = Enum.filter(expunge_lines, &String.ends_with?(&1, "EXPUNGE"))
    assert length(expunge_events) == 2
    assert Enum.all?(expunge_events, &(&1 == "* 1 EXPUNGE"))
    assert Enum.any?(expunge_lines, &String.starts_with?(&1, "A5 OK"))

    _logout = imap_command(socket, "A6", "LOGOUT")
    :ok = close_socket(socket)
  end

  test "IMAP reports RECENT independently from unread counts" do
    {user, password, _mailbox} = create_user_with_messages(2)
    clear_auth_limits(:imap, user.username)

    {:ok, socket} = connect_tcp(imap_port())
    greeting = recv_line!(socket)
    assert String.starts_with?(greeting, "* OK")
    assert greeting =~ "STARTTLS"

    assert Enum.any?(
             imap_command(socket, "ATLS", "STARTTLS"),
             &String.starts_with?(&1, "ATLS OK")
           )

    {:ok, socket} = upgrade_socket_to_tls(socket)

    login_lines = imap_command(socket, "A1", "LOGIN #{user.username} #{password}")
    assert Enum.any?(login_lines, &String.starts_with?(&1, "A1 OK"))

    status_lines = imap_command(socket, "A2", "STATUS INBOX (MESSAGES RECENT UNSEEN)")

    assert Enum.any?(
             status_lines,
             &String.contains?(&1, "STATUS \"INBOX\" (MESSAGES 2 RECENT 2 UNSEEN 2)")
           )

    select_lines = imap_command(socket, "A3", "SELECT INBOX")
    assert Enum.any?(select_lines, &String.starts_with?(&1, "* 2 EXISTS"))
    assert Enum.any?(select_lines, &String.starts_with?(&1, "* 2 RECENT"))
    assert Enum.any?(select_lines, &String.starts_with?(&1, "A3 OK"))

    _logout = imap_command(socket, "A4", "LOGOUT")
    :ok = close_socket(socket)
  end

  test "IMAP RECENT is claimed by the first session that observes a new message" do
    {user, password, mailbox} = create_user_with_messages(0)
    clear_auth_limits(:imap, user.username)

    {:ok, socket1} = connect_tcp(imap_port())
    assert String.starts_with?(recv_line!(socket1), "* OK")
    assert Enum.any?(imap_command(socket1, "S1", "STARTTLS"), &String.starts_with?(&1, "S1 OK"))
    {:ok, socket1} = upgrade_socket_to_tls(socket1)

    assert Enum.any?(
             imap_command(socket1, "S2", "LOGIN #{user.username} #{password}"),
             &String.starts_with?(&1, "S2 OK")
           )

    assert Enum.any?(
             imap_command(socket1, "S3", "SELECT INBOX"),
             &String.starts_with?(&1, "S3 OK")
           )

    {:ok, socket2} = connect_tcp(imap_port())
    assert String.starts_with?(recv_line!(socket2), "* OK")
    assert Enum.any?(imap_command(socket2, "T1", "STARTTLS"), &String.starts_with?(&1, "T1 OK"))
    {:ok, socket2} = upgrade_socket_to_tls(socket2)

    assert Enum.any?(
             imap_command(socket2, "T2", "LOGIN #{user.username} #{password}"),
             &String.starts_with?(&1, "T2 OK")
           )

    assert Enum.any?(
             imap_command(socket2, "T3", "SELECT INBOX"),
             &String.starts_with?(&1, "T3 OK")
           )

    {:ok, _message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        to: mailbox.email,
        from: "recent@example.com",
        subject: "Recent claim",
        text_body: "hello",
        message_id: "recent-claim-#{System.unique_integer([:positive])}@example.com"
      })

    Process.sleep(50)

    noop1 = imap_command(socket1, "S4", "NOOP")
    noop2 = imap_command(socket2, "T4", "NOOP")

    assert Enum.any?(noop1, &String.starts_with?(&1, "* 1 EXISTS"))
    assert Enum.any?(noop2, &String.starts_with?(&1, "* 1 EXISTS"))
    assert Enum.any?(noop1, &String.starts_with?(&1, "* 1 RECENT"))
    assert Enum.any?(noop2, &String.starts_with?(&1, "* 0 RECENT"))

    _logout1 = imap_command(socket1, "S5", "LOGOUT")
    _logout2 = imap_command(socket2, "T5", "LOGOUT")
    :ok = close_socket(socket1)
    :ok = close_socket(socket2)
  end

  test "POP3 UIDL is stable across retrieval operations" do
    {user, password, _mailbox} = create_user_with_messages(2)
    clear_auth_limits(:pop3, user.username)

    {:ok, socket} = connect_tcp(pop3_port())
    assert String.starts_with?(recv_line!(socket), "+OK")

    assert String.starts_with?(
             pop3_command(socket, "USER #{user.username}"),
             "-ERR STLS required"
           )

    assert String.starts_with?(pop3_command(socket, "STLS"), "+OK")
    {:ok, socket} = upgrade_socket_to_tls(socket)

    assert String.starts_with?(pop3_command(socket, "USER #{user.username}"), "+OK")
    assert String.starts_with?(pop3_command(socket, "PASS #{password}"), "+OK")

    {uidl_first, uidl_entries_first} = pop3_multiline_command(socket, "UIDL")
    assert String.starts_with?(uidl_first, "+OK")
    assert length(uidl_entries_first) == 2

    {retr_status, _retr_lines} = pop3_multiline_command(socket, "RETR 1")
    assert String.starts_with?(retr_status, "+OK")

    {uidl_second, uidl_entries_second} = pop3_multiline_command(socket, "UIDL")
    assert String.starts_with?(uidl_second, "+OK")
    assert uidl_entries_second == uidl_entries_first

    assert String.starts_with?(pop3_command(socket, "QUIT"), "+OK")
    :ok = close_socket(socket)
  end

  test "POP3 RETR uses CRLF line endings and dot-stuffs message bodies" do
    password = "ProtocolPass123!"

    user =
      user_fixture(%{
        password: password,
        password_confirmation: password
      })

    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

    message_fixture(%{
      mailbox_id: mailbox.id,
      to: mailbox.email,
      from: "sender@example.com",
      subject: "POP3 framing",
      text_body: "first line\n.starts with dot\nlast line",
      message_id: "pop3-framing-#{System.unique_integer([:positive])}@example.com"
    })

    clear_auth_limits(:pop3, user.username)

    {:ok, socket} = connect_tcp(pop3_port())
    assert String.starts_with?(recv_line!(socket), "+OK")

    assert String.starts_with?(
             pop3_command(socket, "USER #{user.username}"),
             "-ERR STLS required"
           )

    assert String.starts_with?(pop3_command(socket, "STLS"), "+OK")
    {:ok, socket} = upgrade_socket_to_tls(socket)
    assert String.starts_with?(pop3_command(socket, "USER #{user.username}"), "+OK")
    assert String.starts_with?(pop3_command(socket, "PASS #{password}"), "+OK")

    :ok = socket_setopts(socket, packet: :raw)
    send_line!(socket, "RETR 1")
    retr_response = recv_raw_until(socket, "\r\n.\r\n")

    assert retr_response =~ "+OK "
    assert retr_response =~ "\r\nFrom: sender@example.com\r\n"
    assert retr_response =~ "\r\n\r\nfirst line\r\n..starts with dot\r\nlast line"
    assert String.ends_with?(retr_response, "\r\n.\r\n")
    refute retr_response =~ ~r/(^|[^\r])\n/

    :ok = close_socket(socket)
  end

  test "POP3 QUIT commits DELE before acknowledging success" do
    password = "ProtocolPass123!"

    user =
      user_fixture(%{
        password: password,
        password_confirmation: password
      })

    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

    message =
      message_fixture(%{
        mailbox_id: mailbox.id,
        to: mailbox.email,
        from: "sender@example.com",
        subject: "POP3 delete",
        message_id: "pop3-delete-#{System.unique_integer([:positive])}@example.com"
      })

    clear_auth_limits(:pop3, user.username)

    {:ok, socket} = connect_tcp(pop3_port())
    assert String.starts_with?(recv_line!(socket), "+OK")

    assert String.starts_with?(
             pop3_command(socket, "USER #{user.username}"),
             "-ERR STLS required"
           )

    assert String.starts_with?(pop3_command(socket, "STLS"), "+OK")
    {:ok, socket} = upgrade_socket_to_tls(socket)
    assert String.starts_with?(pop3_command(socket, "USER #{user.username}"), "+OK")
    assert String.starts_with?(pop3_command(socket, "PASS #{password}"), "+OK")
    assert String.starts_with?(pop3_command(socket, "DELE 1"), "+OK")
    assert String.starts_with?(pop3_command(socket, "QUIT"), "+OK")
    :ok = close_socket(socket)

    assert {:error, :message_not_found} = Email.get_user_message(message.id, user.id)
  end

  test "POP3 CAPA omits STLS when TLS is not configured" do
    {user, password, _mailbox} = create_user_with_messages(0)
    clear_auth_limits(:pop3, user.username)

    port = unused_tcp_port()

    start_supervised!(
      {Elektrine.POP3.Server,
       [name: :pop3_no_tls_test_server, port: port, tls_opts: [], allow_insecure_auth: true]}
    )

    {:ok, socket} = connect_tcp(port)
    assert String.starts_with?(recv_line!(socket), "+OK")

    {capa_status, capa_lines} = pop3_multiline_command(socket, "CAPA")
    assert String.starts_with?(capa_status, "+OK")
    refute "STLS" in capa_lines

    assert String.starts_with?(pop3_command(socket, "USER #{user.username}"), "+OK")
    assert String.starts_with?(pop3_command(socket, "PASS #{password}"), "+OK")
    assert String.starts_with?(pop3_command(socket, "QUIT"), "+OK")
    :ok = close_socket(socket)
  end

  test "POP3 without TLS and without insecure auth disables USER authentication" do
    port = unused_tcp_port()

    start_supervised!(
      {Elektrine.POP3.Server,
       [name: :pop3_hardened_no_tls_server, port: port, tls_opts: [], allow_insecure_auth: false]}
    )

    {:ok, socket} = connect_tcp(port)
    assert String.starts_with?(recv_line!(socket), "+OK")

    {capa_status, capa_lines} = pop3_multiline_command(socket, "CAPA")
    assert String.starts_with?(capa_status, "+OK")
    refute "STLS" in capa_lines
    refute "USER" in capa_lines
    assert String.starts_with?(pop3_command(socket, "USER demo"), "-ERR STLS required")
    :ok = close_socket(socket)
  end

  test "POP3 advertises STLS when TLS is configured" do
    {user, password, _mailbox} = create_user_with_messages(0)
    clear_auth_limits(:pop3, user.username)

    {:ok, socket} = connect_tcp(pop3_port())
    assert String.starts_with?(recv_line!(socket), "+OK")

    {capa_status, capa_lines} = pop3_multiline_command(socket, "CAPA")
    assert String.starts_with?(capa_status, "+OK")
    assert "STLS" in capa_lines

    assert String.starts_with?(
             pop3_command(socket, "USER #{user.username}"),
             "-ERR STLS required"
           )

    assert String.starts_with?(pop3_command(socket, "STLS"), "+OK")

    {:ok, socket} = upgrade_socket_to_tls(socket)

    assert String.starts_with?(pop3_command(socket, "PASS #{password}"), "-ERR Send USER first")
    assert String.starts_with?(pop3_command(socket, "USER #{user.username}"), "+OK")
    assert String.starts_with?(pop3_command(socket, "PASS #{password}"), "+OK")
    assert String.starts_with?(pop3_command(socket, "QUIT"), "+OK")
    :ok = close_socket(socket)
  end

  test "SMTP handles auth edge cases without crashing auth flow" do
    {user, password, _mailbox} = create_user_with_messages(0)
    clear_auth_limits(:smtp, user.username)

    {:ok, socket} = connect_tcp(smtp_port())
    assert String.starts_with?(recv_line!(socket), "220 ")

    ehlo_lines = smtp_multiline_command(socket, "EHLO localhost")
    assert "250-STARTTLS" in ehlo_lines
    refute Enum.any?(ehlo_lines, &String.contains?(&1, "AUTH"))

    assert String.starts_with?(
             smtp_command(socket, "AUTH LOGIN !!!not-base64!!!"),
             "538 "
           )

    assert String.starts_with?(smtp_command(socket, "STARTTLS"), "220 ")
    {:ok, socket} = upgrade_socket_to_tls(socket)

    ehlo_lines = smtp_multiline_command(socket, "EHLO localhost")
    assert Enum.any?(ehlo_lines, &String.starts_with?(&1, "250 "))
    assert Enum.any?(ehlo_lines, &String.starts_with?(&1, "250-AUTH "))

    assert String.starts_with?(
             smtp_command(socket, "AUTH LOGIN !!!not-base64!!!"),
             "535 "
           )

    assert String.starts_with?(smtp_command(socket, "AUTH LOGIN"), "334 ")
    assert String.starts_with?(smtp_command(socket, "*"), "501 ")

    plain_cred = Base.encode64("\0#{user.username}\0#{password}")

    assert String.starts_with?(
             smtp_command(socket, "AUTH plain #{plain_cred}"),
             "235 "
           )

    assert String.starts_with?(smtp_command(socket, "QUIT"), "221 ")
    :ok = close_socket(socket)
  end

  test "SMTP without TLS and without insecure auth omits AUTH capability" do
    port = unused_tcp_port()

    start_supervised!(
      {Elektrine.SMTP.Server,
       [name: :smtp_hardened_no_tls_server, port: port, tls_opts: [], allow_insecure_auth: false]}
    )

    {:ok, socket} = connect_tcp(port)
    assert String.starts_with?(recv_line!(socket), "220 ")

    ehlo_lines = smtp_multiline_command(socket, "EHLO localhost")
    refute Enum.any?(ehlo_lines, &String.contains?(&1, "STARTTLS"))
    refute Enum.any?(ehlo_lines, &String.contains?(&1, "AUTH"))
    assert String.starts_with?(smtp_command(socket, "AUTH LOGIN"), "538 ")
    :ok = close_socket(socket)
  end

  test "IMAP without TLS and without insecure auth omits auth capabilities" do
    port = unused_tcp_port()

    start_supervised!(
      {Elektrine.IMAP.Server,
       [name: :imap_hardened_no_tls_server, port: port, tls_opts: [], allow_insecure_auth: false]}
    )

    {:ok, socket} = connect_tcp(port)
    greeting = recv_line!(socket)
    assert String.starts_with?(greeting, "* OK")
    refute greeting =~ "STARTTLS"
    refute greeting =~ "AUTH=PLAIN"
    refute greeting =~ "AUTH=LOGIN"

    capability_lines = imap_command(socket, "A1", "CAPABILITY")
    refute Enum.any?(capability_lines, &String.contains?(&1, "STARTTLS"))
    refute Enum.any?(capability_lines, &String.contains?(&1, "AUTH=PLAIN"))
    refute Enum.any?(capability_lines, &String.contains?(&1, "AUTH=LOGIN"))

    login_lines = imap_command(socket, "A2", "LOGIN demo password")
    assert Enum.any?(login_lines, &String.starts_with?(&1, "A2 NO STARTTLS required"))
    :ok = close_socket(socket)
  end

  test "SMTP QUIT sends a single terminal response" do
    {:ok, socket} = connect_tcp(smtp_port())
    assert String.starts_with?(recv_line!(socket), "220 ")

    send_line!(socket, "QUIT")
    assert recv_line!(socket) == "221 Bye"
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  defp create_user_with_messages(message_count) do
    password = "ProtocolPass123!"

    user =
      user_fixture(%{
        password: password,
        password_confirmation: password
      })

    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

    if message_count > 0 do
      Enum.each(1..message_count, fn idx ->
        message_fixture(%{
          mailbox_id: mailbox.id,
          to: mailbox.email,
          from: "sender#{idx}@example.com",
          subject: "Protocol Message #{idx}",
          message_id: "protocol-#{System.unique_integer([:positive])}-#{idx}@example.com"
        })
      end)
    end

    {user, password, mailbox}
  end

  defp clear_auth_limits(:imap, username) do
    IMAPRateLimiter.clear_attempts("127.0.0.1")
    MailAuthRateLimiter.clear_attempts(:imap, username)
  end

  defp clear_auth_limits(:pop3, username) do
    POP3RateLimiter.clear_attempts("127.0.0.1")
    MailAuthRateLimiter.clear_attempts(:pop3, username)
  end

  defp clear_auth_limits(:smtp, username) do
    SMTPRateLimiter.clear_attempts("127.0.0.1")
    MailAuthRateLimiter.clear_attempts(:smtp, username)
  end

  defp imap_port, do: Application.get_env(:elektrine, :imap_port, 2143)
  defp pop3_port, do: Application.get_env(:elektrine, :pop3_port, 2110)
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

  defp imap_command(socket, tag, command) do
    send_line!(socket, "#{tag} #{command}")
    recv_imap_until_tag(socket, tag, [])
  end

  defp recv_imap_until_tag(socket, tag, acc) do
    line = recv_line!(socket)
    next_acc = [line | acc]

    if String.starts_with?(line, "#{tag} ") do
      Enum.reverse(next_acc)
    else
      recv_imap_until_tag(socket, tag, next_acc)
    end
  end

  defp pop3_command(socket, command) do
    send_line!(socket, command)
    recv_line!(socket)
  end

  defp pop3_multiline_command(socket, command) do
    send_line!(socket, command)
    status = recv_line!(socket)
    lines = recv_pop3_until_dot(socket, [])
    {status, lines}
  end

  defp recv_pop3_until_dot(socket, acc) do
    line = recv_line!(socket)

    if line == "." do
      Enum.reverse(acc)
    else
      recv_pop3_until_dot(socket, [line | acc])
    end
  end

  defp recv_raw_until(socket, terminator, acc \\ "") do
    if String.contains?(acc, terminator) do
      acc
    else
      case socket_recv(socket, 4_000) do
        {:ok, data} -> recv_raw_until(socket, terminator, acc <> data)
        {:error, reason} -> raise "Socket raw recv failed: #{inspect(reason)}"
      end
    end
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

  defp socket_setopts(socket, opts) do
    if ssl_socket?(socket), do: :ssl.setopts(socket, opts), else: :inet.setopts(socket, opts)
  end

  defp ssl_socket?(socket)
       when is_tuple(socket) and tuple_size(socket) > 0 and elem(socket, 0) == :sslsocket,
       do: true

  defp ssl_socket?(_socket), do: false

  defp unused_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
