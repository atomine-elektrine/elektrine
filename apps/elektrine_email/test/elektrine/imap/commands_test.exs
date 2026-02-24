defmodule Elektrine.IMAP.CommandsTest do
  use Elektrine.DataCase, async: false

  import Ecto.Query
  import Elektrine.AccountsFixtures
  import Elektrine.EmailFixtures
  alias Elektrine.IMAP.Commands
  alias Elektrine.Accounts.User
  alias Elektrine.Email
  alias Elektrine.Repo

  test "capability_string/1 advertises only implemented baseline capabilities" do
    unauth = Commands.capability_string(:not_authenticated)
    auth = Commands.capability_string(:authenticated)

    assert unauth =~ "IMAP4rev1"
    assert unauth =~ "AUTH=PLAIN"
    assert unauth =~ "AUTH=LOGIN"
    assert unauth =~ "UIDPLUS"
    assert unauth =~ "IDLE"
    assert unauth =~ "QUOTA"
    assert unauth =~ "THREAD=REFERENCES"
    assert unauth =~ "LIST-EXTENDED"
    assert unauth =~ "LIST-STATUS"

    refute unauth =~ "IMAP4rev2"
    refute unauth =~ "QRESYNC"
    refute unauth =~ "CONDSTORE"
    refute unauth =~ "OBJECTID"

    assert auth =~ "IMAP4rev1"
    refute auth =~ "AUTH=PLAIN"
    refute auth =~ "AUTH=LOGIN"
    assert auth =~ "QUOTA"
    assert auth =~ "THREAD=REFERENCES"
    assert auth =~ "LIST-EXTENDED"
    assert auth =~ "LIST-STATUS"
  end

  test "AUTHENTICATE PLAIN accepts initial response and records IMAP access" do
    user = user_fixture()

    encoded =
      Base.encode64("\u0000#{user.username}\u0000#{valid_user_password()}", padding: false)

    {server_socket, client_socket} = socket_pair()

    state = %{
      socket: server_socket,
      state: :not_authenticated,
      authenticated: false,
      user: nil,
      username: nil,
      mailbox: nil,
      uid_validity: nil,
      selected_folder: nil,
      messages: [],
      client_ip: "127.0.0.2"
    }

    assert {:continue, new_state} =
             Commands.process_command("A005", "AUTHENTICATE", "PLAIN #{encoded}", state)

    assert new_state.state == :authenticated
    assert new_state.authenticated == true
    assert new_state.user.id == user.id
    assert new_state.mailbox.user_id == user.id
    assert new_state.uid_validity == new_state.mailbox.id

    response = read_until(client_socket, "A005 OK")
    assert response =~ "A005 OK [CAPABILITY"
    assert response =~ "Logged in"

    refreshed_user = Repo.get!(User, user.id)
    assert refreshed_user.last_imap_access

    :gen_tcp.close(client_socket)
    :gen_tcp.close(server_socket)
  end

  test "GETQUOTA returns dynamic user storage values in RFC 2087 units" do
    user = user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(set: [storage_used_bytes: 10_000, storage_limit_bytes: 100_000])

    {server_socket, client_socket} = socket_pair()

    state = %{
      socket: server_socket,
      state: :authenticated,
      user: user,
      mailbox: mailbox,
      uid_validity: mailbox.id,
      selected_folder: nil,
      messages: []
    }

    assert {:continue, _new_state} = Commands.process_command("A001", "GETQUOTA", "\"\"", state)

    response = read_until(client_socket, "A001 OK GETQUOTA completed")

    assert response =~ "* QUOTA \"\" (STORAGE 10 98)\r\n"
    assert response =~ "A001 OK GETQUOTA completed\r\n"

    :gen_tcp.close(client_socket)
    :gen_tcp.close(server_socket)
  end

  test "LIST with RETURN STATUS emits per-folder status details" do
    user = user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
    _message = message_fixture(%{mailbox_id: mailbox.id, to: mailbox.email})
    {server_socket, client_socket} = socket_pair()

    state = %{
      socket: server_socket,
      state: :authenticated,
      user: %{id: user.id},
      mailbox: mailbox,
      uid_validity: mailbox.id,
      selected_folder: nil,
      messages: []
    }

    assert {:continue, _state} =
             Commands.process_command(
               "A010",
               "LIST",
               "\"\" \"INBOX\" RETURN (STATUS (MESSAGES UNSEEN UIDNEXT))",
               state
             )

    response = read_until(client_socket, "A010 OK LIST completed")
    assert response =~ "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n"
    assert response =~ "* STATUS \"INBOX\" ("
    assert response =~ "MESSAGES "
    assert response =~ "UNSEEN "
    assert response =~ "UIDNEXT "

    :gen_tcp.close(client_socket)
    :gen_tcp.close(server_socket)
  end

  test "SUBSCRIBE and UNSUBSCRIBE affect LSUB output" do
    user = user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

    {:ok, _folder} =
      Email.create_custom_folder(%{
        name: "Projects",
        user_id: user.id,
        color: "#3b82f6",
        icon: "folder"
      })

    {server_socket, client_socket} = socket_pair()

    state = %{
      socket: server_socket,
      state: :authenticated,
      user: %{id: user.id},
      mailbox: mailbox,
      uid_validity: mailbox.id
    }

    assert {:continue, _state} =
             Commands.process_command("A020", "UNSUBSCRIBE", "\"Sent\"", state)

    _unsubscribe_response = read_until(client_socket, "A020 OK UNSUBSCRIBE completed")

    assert {:continue, _state} = Commands.process_command("A021", "LSUB", "\"\" \"*\"", state)
    lsub_after_unsubscribe = read_until(client_socket, "A021 OK LSUB completed")
    refute lsub_after_unsubscribe =~ "\"Sent\""
    assert lsub_after_unsubscribe =~ "\"INBOX\""
    assert lsub_after_unsubscribe =~ "\"Projects\""

    assert {:continue, _state} = Commands.process_command("A022", "SUBSCRIBE", "\"Sent\"", state)
    _subscribe_response = read_until(client_socket, "A022 OK SUBSCRIBE completed")

    assert {:continue, _state} = Commands.process_command("A023", "LSUB", "\"\" \"*\"", state)
    lsub_after_subscribe = read_until(client_socket, "A023 OK LSUB completed")
    assert lsub_after_subscribe =~ "\"Sent\""

    :gen_tcp.close(client_socket)
    :gen_tcp.close(server_socket)
  end

  test "THREAD command is supported in selected state" do
    user = user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
    _msg1 = message_fixture(%{mailbox_id: mailbox.id, to: mailbox.email})
    _msg2 = message_fixture(%{mailbox_id: mailbox.id, to: mailbox.email})

    messages = Email.list_messages_for_imap(mailbox.id, :inbox)
    {server_socket, client_socket} = socket_pair()

    state = %{
      socket: server_socket,
      state: :selected,
      user: %{id: user.id},
      mailbox: mailbox,
      uid_validity: mailbox.id,
      selected_folder: "INBOX",
      messages: messages
    }

    assert {:continue, _state} =
             Commands.process_command("A030", "THREAD", "REFERENCES UTF-8 ALL", state)

    response = read_until(client_socket, "A030 OK THREAD completed")
    assert response =~ "* THREAD"

    :gen_tcp.close(client_socket)
    :gen_tcp.close(server_socket)
  end

  test "COPY returns COPYUID when messages are copied" do
    user = user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
    message = message_fixture(%{mailbox_id: mailbox.id, to: mailbox.email})
    {server_socket, client_socket} = socket_pair()

    state = %{
      socket: server_socket,
      state: :selected,
      user: %{id: user.id},
      mailbox: mailbox,
      uid_validity: mailbox.id,
      selected_folder: "INBOX",
      messages: [message]
    }

    assert {:continue, _state} = Commands.process_command("A040", "COPY", "1 \"Sent\"", state)

    response = read_until(client_socket, "A040 OK")
    assert response =~ ~r/A040 OK \[COPYUID \d+ #{message.id} \d+\] COPY completed\r\n/

    :gen_tcp.close(client_socket)
    :gen_tcp.close(server_socket)
  end

  test "UID COPY returns COPYUID when messages are copied" do
    user = user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
    message = message_fixture(%{mailbox_id: mailbox.id, to: mailbox.email})
    {server_socket, client_socket} = socket_pair()

    state = %{
      socket: server_socket,
      state: :selected,
      user: %{id: user.id},
      mailbox: mailbox,
      uid_validity: mailbox.id,
      selected_folder: "INBOX",
      messages: [message]
    }

    assert {:continue, _state} =
             Commands.process_command("A050", "UID", "COPY #{message.id} \"Sent\"", state)

    response = read_until(client_socket, "A050 OK")
    assert response =~ ~r/A050 OK \[COPYUID \d+ #{message.id} \d+\] UID COPY completed\r\n/

    :gen_tcp.close(client_socket)
    :gen_tcp.close(server_socket)
  end

  test "EXAMINE accepts mailbox parameters and still selects INBOX" do
    user = user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
    _message = message_fixture(%{mailbox_id: mailbox.id, to: mailbox.email})
    {server_socket, client_socket} = socket_pair()

    state = %{
      socket: server_socket,
      state: :authenticated,
      user: %{id: user.id},
      mailbox: mailbox,
      uid_validity: mailbox.id,
      selected_folder: nil,
      messages: []
    }

    assert {:continue, new_state} =
             Commands.process_command("A060", "EXAMINE", "\"INBOX\" (CONDSTORE)", state)

    assert new_state.selected_folder == "INBOX"
    response = read_until(client_socket, "A060 OK [READ-ONLY] EXAMINE completed")
    assert response =~ "* 1 EXISTS\r\n"

    :gen_tcp.close(client_socket)
    :gen_tcp.close(server_socket)
  end

  test "UID FETCH handles Apple Mail header field request format" do
    user = user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

    message =
      message_fixture(%{mailbox_id: mailbox.id, to: mailbox.email, text_body: "Hello body"})

    {server_socket, client_socket} = socket_pair()

    state = %{
      socket: server_socket,
      state: :selected,
      user: %{id: user.id},
      mailbox: mailbox,
      uid_validity: mailbox.id,
      selected_folder: "INBOX",
      messages: [message]
    }

    fetch_args =
      "FETCH #{message.id} (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (DATE FROM SUBJECT TO CC MESSAGE-ID REFERENCES IN-REPLY-TO)] BODY.PEEK[TEXT]<0.5>)"

    assert {:continue, _state} = Commands.process_command("A070", "UID", fetch_args, state)

    response = read_until(client_socket, "A070 OK UID FETCH completed")

    assert response =~ "UID #{message.id}"
    assert response =~ "FLAGS ("
    assert response =~ "INTERNALDATE \""
    assert response =~ "RFC822.SIZE "

    assert response =~
             "BODY[HEADER.FIELDS (DATE FROM SUBJECT TO CC MESSAGE-ID REFERENCES IN-REPLY-TO)]"

    assert response =~ "BODY[TEXT]<0> {5}\r\nHello"

    :gen_tcp.close(client_socket)
    :gen_tcp.close(server_socket)
  end

  defp socket_pair do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, {:active, false}, {:packet, :raw}, {:reuseaddr, true}])

    {:ok, {_addr, port}} = :inet.sockname(listener)
    {:ok, client_socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    {:ok, server_socket} = :gen_tcp.accept(listener)
    :gen_tcp.close(listener)
    {server_socket, client_socket}
  end

  defp read_until(socket, terminator, acc \\ "") do
    if String.contains?(acc, terminator) do
      acc
    else
      case :gen_tcp.recv(socket, 0, 1000) do
        {:ok, data} ->
          read_until(socket, terminator, acc <> data)

        {:error, :timeout} ->
          flunk("Timed out waiting for IMAP response containing #{inspect(terminator)}")
      end
    end
  end
end
