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

    assert Enum.any?(store_lines, &String.starts_with?(&1, "A4 OK"))

    expunge_lines = imap_command(socket, "A5", "EXPUNGE")
    expunge_events = Enum.filter(expunge_lines, &String.ends_with?(&1, "EXPUNGE"))
    assert length(expunge_events) == 2
    assert Enum.all?(expunge_events, &(&1 == "* 1 EXPUNGE"))
    assert Enum.any?(expunge_lines, &String.starts_with?(&1, "A5 OK"))

    _logout = imap_command(socket, "A6", "LOGOUT")
    :ok = :gen_tcp.close(socket)
  end

  test "POP3 UIDL is stable across retrieval operations" do
    {user, password, _mailbox} = create_user_with_messages(2)
    clear_auth_limits(:pop3, user.username)

    {:ok, socket} = connect_tcp(pop3_port())
    assert String.starts_with?(recv_line!(socket), "+OK")

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
    :ok = :gen_tcp.close(socket)
  end

  test "SMTP handles auth edge cases without crashing auth flow" do
    {user, password, _mailbox} = create_user_with_messages(0)
    clear_auth_limits(:smtp, user.username)

    {:ok, socket} = connect_tcp(smtp_port())
    assert String.starts_with?(recv_line!(socket), "220 ")

    ehlo_lines = smtp_multiline_command(socket, "EHLO localhost")
    assert Enum.any?(ehlo_lines, &String.starts_with?(&1, "250 "))

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
    :ok = :gen_tcp.close(socket)
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
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} -> String.trim_trailing(to_string(data), "\r\n")
      {:error, reason} -> raise "TCP recv failed: #{inspect(reason)}"
    end
  end

  defp send_line!(socket, line) do
    :ok = :gen_tcp.send(socket, "#{line}\r\n")
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
end
