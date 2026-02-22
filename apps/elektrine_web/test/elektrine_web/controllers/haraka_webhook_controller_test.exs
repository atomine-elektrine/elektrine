defmodule ElektrineWeb.HarakaWebhookControllerTest do
  use ElektrineWeb.ConnCase
  import Elektrine.AccountsFixtures
  import Elektrine.EmailFixtures

  alias Elektrine.Email

  @api_key "test_haraka_api_key"

  setup do
    # Set test API key
    System.put_env("HARAKA_API_KEY", @api_key)
    old_async_setting = Application.get_env(:elektrine, :haraka_async_ingest, true)
    Application.put_env(:elektrine, :haraka_async_ingest, false)

    on_exit(fn ->
      System.delete_env("HARAKA_API_KEY")
      Application.put_env(:elektrine, :haraka_async_ingest, old_async_setting)
    end)

    :ok
  end

  defp auth_conn(conn) do
    conn
    |> put_req_header("x-api-key", @api_key)
    |> put_req_header("content-type", "application/json")
  end

  defp spoof_alert_messages(mailbox_id) do
    mailbox_id
    |> Email.list_inbox_messages()
    |> Enum.filter(&(&1.subject == "Security Alert: Email spoofing attempt detected"))
  end

  defp assert_spoof_alert_count(mailbox_id, expected_count, attempts \\ 20)

  defp assert_spoof_alert_count(mailbox_id, expected_count, attempts) when attempts > 0 do
    actual_count = mailbox_id |> spoof_alert_messages() |> length()

    if actual_count == expected_count do
      :ok
    else
      Process.sleep(25)
      assert_spoof_alert_count(mailbox_id, expected_count, attempts - 1)
    end
  end

  defp assert_spoof_alert_count(mailbox_id, expected_count, 0) do
    actual_count = mailbox_id |> spoof_alert_messages() |> length()
    assert actual_count == expected_count
  end

  describe "mailing list email handling" do
    setup do
      # Create a user with a mailbox
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "testuser@elektrine.com"})

      {:ok, user: user, mailbox: mailbox}
    end

    test "delivers email when rcpt_to has local address and to has mailing list address", %{
      conn: conn,
      mailbox: mailbox
    } do
      # Simulates a Debian mailing list email where:
      # - To: debian-user@lists.debian.org (the mailing list)
      # - rcpt_to: testuser@elektrine.com (actual recipient)
      params = %{
        "from" => "sender@example.com",
        "to" => "debian-user@lists.debian.org",
        "rcpt_to" => "testuser@elektrine.com",
        "subject" => "Test mailing list message",
        "text_body" => "This is a test message from a mailing list",
        "html_body" => "<p>This is a test message from a mailing list</p>",
        "message_id" => "test-mailing-list-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      # Verify message was delivered to the correct mailbox
      messages = Email.list_inbox_messages(mailbox.id)
      assert length(messages) == 1
      [message] = messages
      assert message.subject == "Test mailing list message"
      assert message.mailbox_id == mailbox.id
    end

    test "delivers email when to header has local address", %{conn: conn, mailbox: mailbox} do
      # Normal direct email where To header has the local address
      params = %{
        "from" => "sender@example.com",
        "to" => "testuser@elektrine.com",
        "rcpt_to" => "testuser@elektrine.com",
        "subject" => "Direct email test",
        "text_body" => "This is a direct email",
        "message_id" => "test-direct-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      messages = Email.list_inbox_messages(mailbox.id)
      assert length(messages) == 1
    end

    test "prefers cleaner subject decoding from raw Subject header when payload subject is mojibake",
         %{conn: conn, mailbox: mailbox} do
      params = %{
        "from" => "sender@example.com",
        "to" => "testuser@elektrine.com",
        "rcpt_to" => "testuser@elektrine.com",
        "subject" => "xiha711@gmail.com çå®å¨æé",
        "headers" => %{
          "Subject" => "=?UTF-8?B?eGloYTcxMUBnbWFpbC5jb20g55qE5a6J5YWo5o+Q6YaS?="
        },
        "text_body" => "Encoding fallback test",
        "message_id" => "test-encoding-fallback-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      [message] =
        mailbox.id
        |> Email.list_inbox_messages()
        |> Enum.filter(&(&1.message_id == params["message_id"]))

      assert message.subject == "xiha711@gmail.com 的安全提醒"
    end

    test "prefers rcpt_to over to header when both have different addresses", %{
      conn: conn,
      mailbox: mailbox
    } do
      # Email where To has external address but rcpt_to has local
      # Use generic sender/subject to avoid auto-categorization as feed/digest
      params = %{
        "from" => "support@company.com",
        "to" => "team@company.com",
        "rcpt_to" => "testuser@elektrine.com",
        "subject" => "Important update",
        "text_body" => "This is important information",
        "message_id" => "test-team-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      # Use a broader query to find all messages for this mailbox
      import Ecto.Query

      messages =
        Elektrine.Email.Message
        |> where(mailbox_id: ^mailbox.id)
        |> where([m], m.deleted == false)
        |> Elektrine.Repo.all()

      assert length(messages) == 1
      [message] = messages
      assert message.mailbox_id == mailbox.id
    end

    test "handles multiple recipients in to header with local rcpt_to", %{
      conn: conn,
      mailbox: mailbox
    } do
      # Mailing list with multiple recipients in To header
      params = %{
        "from" => "sender@example.com",
        "to" => "list1@lists.example.org, list2@other.org",
        "rcpt_to" => "testuser@elektrine.com",
        "subject" => "Multi-recipient test",
        "text_body" => "Test content",
        "message_id" => "test-multi-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      messages = Email.list_inbox_messages(mailbox.id)
      assert length(messages) == 1
    end

    test "rejects email when neither to nor rcpt_to has valid local address", %{conn: conn} do
      params = %{
        "from" => "sender@example.com",
        "to" => "external@other.com",
        "rcpt_to" => "another@external.org",
        "subject" => "Should be rejected",
        "text_body" => "This should not be delivered",
        "message_id" => "test-reject-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      # Should return error indicating no mailbox
      response = json_response(conn, 404)
      assert response["error"] =~ "Mailbox"
    end

    test "handles z.org domain in rcpt_to for mailing lists", %{conn: conn} do
      # Create a z.org mailbox
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "zorguser@z.org"})

      params = %{
        "from" => "sender@lists.debian.org",
        "to" => "debian-announce@lists.debian.org",
        "rcpt_to" => "zorguser@z.org",
        "subject" => "Debian announcement",
        "text_body" => "Important announcement",
        "message_id" => "test-zorg-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      messages = Email.list_inbox_messages(mailbox.id)
      assert length(messages) == 1
    end

    test "handles email with angle brackets in to header", %{conn: conn, mailbox: mailbox} do
      # Some mailing lists use "List Name <list@domain.org>" format
      params = %{
        "from" => "sender@example.com",
        "to" => "Debian Users <debian-user@lists.debian.org>",
        "rcpt_to" => "testuser@elektrine.com",
        "subject" => "Formatted To header test",
        "text_body" => "Test content",
        "message_id" => "test-formatted-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      messages = Email.list_inbox_messages(mailbox.id)
      assert length(messages) == 1
    end

    test "handles case-insensitive email matching", %{conn: conn, mailbox: mailbox} do
      params = %{
        "from" => "sender@example.com",
        "to" => "debian-user@lists.debian.org",
        "rcpt_to" => "TESTUSER@ELEKTRINE.COM",
        "subject" => "Case insensitive test",
        "text_body" => "Test content",
        "message_id" => "test-case-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      messages = Email.list_inbox_messages(mailbox.id)
      assert length(messages) == 1
      [message] = messages
      assert message.mailbox_id == mailbox.id
    end
  end

  describe "decode_mime_header_public" do
    # Haraka now handles MIME decoding with postal-mime
    # Phoenix just passes through with basic cleanup

    test "passes through already-decoded text from Haraka" do
      # Haraka sends pre-decoded UTF-8 text
      result =
        ElektrineWeb.HarakaWebhookController.decode_mime_header_public("Hello World")

      assert result == "Hello World"
    end

    test "passes through Chinese text from Haraka" do
      # Haraka decodes GB2312/GBK/UTF-8 with postal-mime
      result =
        ElektrineWeb.HarakaWebhookController.decode_mime_header_public("账号安全中心-绑定邮箱验证")

      assert result == "账号安全中心-绑定邮箱验证"
    end

    test "handles plain text headers" do
      result =
        ElektrineWeb.HarakaWebhookController.decode_mime_header_public("Plain Text Subject")

      assert result == "Plain Text Subject"
    end

    test "handles empty headers" do
      assert ElektrineWeb.HarakaWebhookController.decode_mime_header_public("") == ""
      assert ElektrineWeb.HarakaWebhookController.decode_mime_header_public(nil) == ""
    end

    test "decodes RFC 2047 base64 encoded UTF-8 headers" do
      encoded = "=?UTF-8?B?eGloYTcxMUBnbWFpbC5jb20g55qE5a6J5YWo5o+Q6YaS?="

      assert ElektrineWeb.HarakaWebhookController.decode_mime_header_public(encoded) ==
               "xiha711@gmail.com 的安全提醒"
    end
  end

  describe "verify_recipient endpoint" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "existing@elektrine.com"})
      {:ok, mailbox: mailbox}
    end

    test "returns exists: true for existing mailbox", %{conn: conn} do
      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/verify-recipient", %{"email" => "existing@elektrine.com"})

      assert json_response(conn, 200) == %{"exists" => true, "email" => "existing@elektrine.com"}
    end

    test "returns exists: true for supported cross-domain mailbox", %{conn: conn} do
      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/verify-recipient", %{"email" => "existing@z.org"})

      assert json_response(conn, 200) == %{"exists" => true, "email" => "existing@z.org"}
    end

    test "returns exists: false for non-existing mailbox", %{conn: conn} do
      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/verify-recipient", %{"email" => "nonexistent@elektrine.com"})

      assert json_response(conn, 404) == %{
               "exists" => false,
               "email" => "nonexistent@elektrine.com"
             }
    end

    test "rejects request without API key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/haraka/verify-recipient", %{"email" => "test@elektrine.com"})

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end
  end

  describe "async inbound ingest" do
    setup do
      old_async_setting = Application.get_env(:elektrine, :haraka_async_ingest, false)
      Application.put_env(:elektrine, :haraka_async_ingest, true)

      on_exit(fn ->
        Application.put_env(:elektrine, :haraka_async_ingest, old_async_setting)
      end)

      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "asyncuser@elektrine.com"})
      {:ok, mailbox: mailbox}
    end

    test "queues inbound payload and preserves envelope recipient metadata", %{
      conn: conn,
      mailbox: mailbox
    } do
      params = %{
        "from" => "sender@example.com",
        "to" => "dev-list@lists.example.org",
        "rcpt_to" => "asyncuser@z.org",
        "subject" => "Async ingest metadata test",
        "text_body" => "payload body",
        "message_id" => "async-metadata-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      response = json_response(conn, 200)
      assert response["status"] == "queued"
      assert response["queue"] == "email_inbound"
      assert response["enqueue_outcome"] in ["queued", "duplicate"]
      assert is_binary(response["idempotency_key"])

      import Ecto.Query

      messages =
        Elektrine.Email.Message
        |> where(mailbox_id: ^mailbox.id)
        |> where([m], m.message_id == ^params["message_id"])
        |> Elektrine.Repo.all()

      assert length(messages) == 1
      [message] = messages
      assert message.metadata["envelope_rcpt_to"] == "asyncuser@z.org"
      assert message.metadata["ingest_mode"] == "async"
      assert is_binary(message.metadata["ingest_idempotency_key"])
    end

    test "marks duplicate enqueue outcome for repeated payload", %{conn: conn, mailbox: mailbox} do
      unique_suffix = System.system_time(:millisecond)

      params = %{
        "from" => "sender@example.com",
        "to" => "updates@lists.example.org",
        "rcpt_to" => "asyncuser@z.org",
        "subject" => "Duplicate async payload",
        "text_body" => "same body",
        "message_id" => "async-dup-#{unique_suffix}"
      }

      first_conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      second_conn =
        build_conn()
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(first_conn, 200)["status"] == "queued"
      assert json_response(second_conn, 200)["enqueue_outcome"] == "duplicate"

      import Ecto.Query

      message_count =
        Elektrine.Email.Message
        |> where(mailbox_id: ^mailbox.id)
        |> where([m], m.message_id == ^params["message_id"])
        |> Elektrine.Repo.aggregate(:count, :id)

      assert message_count == 1
    end

    test "returns bounce response for invalid recipient before enqueue", %{conn: conn} do
      params = %{
        "from" => "sender@example.com",
        "to" => "external@outside.net",
        "rcpt_to" => "other@outside.net",
        "subject" => "Should bounce",
        "text_body" => "invalid recipient",
        "message_id" => "async-bounce-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      response = json_response(conn, 404)
      assert response["error"] == "Mailbox does not exist"
      assert response["bounce"] == true
    end
  end

  describe "authentication" do
    test "rejects requests with invalid API key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-api-key", "invalid_key")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/haraka/inbound", %{
          "from" => "test@example.com",
          "to" => "user@elektrine.com",
          "subject" => "Test"
        })

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end

    test "rejects requests without API key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/haraka/inbound", %{
          "from" => "test@example.com",
          "to" => "user@elektrine.com",
          "subject" => "Test"
        })

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end

    test "rejects invalid content-length header", %{conn: conn} do
      conn =
        conn
        |> auth_conn()
        |> put_req_header("content-length", "not-a-number")
        |> post(~p"/api/haraka/inbound", %{
          "from" => "sender@example.com",
          "to" => "user@elektrine.com",
          "rcpt_to" => "user@elektrine.com",
          "subject" => "Test"
        })

      assert json_response(conn, 400)["error"] == "Invalid Content-Length header"
    end
  end

  describe "local-domain spoofing hardening" do
    test "rejects unauthenticated local-domain sender and sends spoof alert", %{conn: conn} do
      local_part = "victim#{System.unique_integer([:positive])}"
      user = user_fixture(%{username: local_part})
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
      spoofed_from = mailbox.email

      params = %{
        "from" => spoofed_from,
        "to" => spoofed_from,
        "rcpt_to" => spoofed_from,
        "subject" => "Spoof attempt",
        "text_body" => "malicious",
        "message_id" => "spoof-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 403)["error"] == "Message rejected for security reasons"
      assert_spoof_alert_count(mailbox.id, 1)
    end

    test "does not send spoof alert for non-spoof security rejection", %{conn: conn} do
      local_part = "victim#{System.unique_integer([:positive])}"
      user = user_fixture(%{username: local_part})
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
      sender = mailbox.email

      params = %{
        "from" => sender,
        "to" => sender,
        "rcpt_to" => sender,
        "subject" => "Header tampering",
        "text_body" => "malicious",
        "authenticated" => true,
        "raw" =>
          "From: #{sender}\r\nFrom: attacker@example.com\r\nTo: #{sender}\r\nSubject: Header tampering\r\n\r\nbody",
        "message_id" => "multi-from-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 403)["error"] == "Message rejected for security reasons"
      assert_spoof_alert_count(mailbox.id, 0)
    end

    test "allows local-domain sender with authenticated submission marker", %{conn: conn} do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "recipient@elektrine.com"})

      params = %{
        "from" => "trusted@elektrine.com",
        "to" => "recipient@elektrine.com",
        "rcpt_to" => "recipient@elektrine.com",
        "subject" => "Authenticated local delivery",
        "text_body" => "hello",
        "authenticated" => true,
        "message_id" => "auth-local-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"
      assert length(Email.list_inbox_messages(mailbox.id)) == 1
    end
  end

  describe "cross-domain mailing lists" do
    test "delivers mailing list email to elektrine.com user from z.org rcpt_to format", %{
      conn: conn
    } do
      # User has elektrine.com mailbox but could receive via z.org address
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "crossdomain@elektrine.com"})

      params = %{
        "from" => "list-owner@lists.example.org",
        "to" => "discussion@lists.example.org",
        "rcpt_to" => "crossdomain@z.org",
        "subject" => "Cross domain test",
        "text_body" => "Testing cross domain delivery",
        "message_id" => "test-cross-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      import Ecto.Query

      messages =
        Elektrine.Email.Message
        |> where(mailbox_id: ^mailbox.id)
        |> Elektrine.Repo.all()

      assert length(messages) == 1
    end

    test "verify endpoint accepts z.org address for elektrine.com mailbox", %{conn: conn} do
      user = user_fixture()
      _mailbox = mailbox_fixture(%{user_id: user.id, email: "crossverify@elektrine.com"})

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/verify-recipient", %{"email" => "crossverify@z.org"})

      assert json_response(conn, 200) == %{"exists" => true, "email" => "crossverify@z.org"}
    end
  end

  describe "delivery signal suppression automation" do
    setup do
      local_part = "signals#{System.unique_integer([:positive])}"
      user = user_fixture(%{username: local_part})
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
      {:ok, user: user, mailbox: mailbox}
    end

    test "creates suppression for hard bounce DSN recipient", %{
      conn: conn,
      user: user,
      mailbox: mailbox
    } do
      params = %{
        "from" => "Mail Delivery Subsystem <mailer-daemon@example.net>",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Delivery Status Notification (Failure)",
        "text_body" =>
          "Final-Recipient: rfc822; bounced@example.net\nStatus: 5.1.1\nDiagnostic-Code: smtp; 550 5.1.1 User unknown",
        "headers" => %{
          "Final-Recipient" => "rfc822; bounced@example.net",
          "Status" => "5.1.1"
        },
        "message_id" => "dsn-hard-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      suppression = Email.get_active_suppression(user.id, "bounced@example.net")
      assert suppression
      assert suppression.reason == "hard_bounce"
    end

    test "creates suppression for feedback-loop complaint recipient", %{
      conn: conn,
      user: user,
      mailbox: mailbox
    } do
      params = %{
        "from" => "complaints@example.net",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Abuse report",
        "text_body" => "Original-Recipient: rfc822; complainant@example.org",
        "headers" => %{
          "Feedback-Type" => "abuse",
          "Original-Recipient" => "rfc822; complainant@example.org"
        },
        "message_id" => "fbl-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      suppression = Email.get_active_suppression(user.id, "complainant@example.org")
      assert suppression
      assert suppression.reason == "complaint"
    end
  end

  describe "edge cases for mailing lists" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "edgecase@elektrine.com"})
      {:ok, user: user, mailbox: mailbox}
    end

    test "handles empty to header with valid rcpt_to", %{conn: conn, mailbox: mailbox} do
      params = %{
        "from" => "sender@example.com",
        "to" => "",
        "rcpt_to" => "edgecase@elektrine.com",
        "subject" => "Empty to header test",
        "text_body" => "Test content",
        "message_id" => "test-empty-to-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      import Ecto.Query

      messages =
        Elektrine.Email.Message
        |> where(mailbox_id: ^mailbox.id)
        |> Elektrine.Repo.all()

      assert length(messages) == 1
    end

    test "handles nil to header with valid rcpt_to", %{conn: conn, mailbox: mailbox} do
      params = %{
        "from" => "sender@example.com",
        "rcpt_to" => "edgecase@elektrine.com",
        "subject" => "Nil to header test",
        "text_body" => "Test content",
        "message_id" => "test-nil-to-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      import Ecto.Query

      messages =
        Elektrine.Email.Message
        |> where(mailbox_id: ^mailbox.id)
        |> Elektrine.Repo.all()

      assert length(messages) == 1
    end

    test "handles mailing list with Reply-To different from From", %{conn: conn, mailbox: mailbox} do
      # Common mailing list pattern where Reply-To goes back to the list
      params = %{
        "from" => "author@personal.com",
        "to" => "tech-list@lists.example.org",
        "rcpt_to" => "edgecase@elektrine.com",
        "reply_to" => "tech-list@lists.example.org",
        "subject" => "Re: Technical discussion",
        "text_body" => "My response to the thread",
        "message_id" => "test-reply-to-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      import Ecto.Query

      messages =
        Elektrine.Email.Message
        |> where(mailbox_id: ^mailbox.id)
        |> Elektrine.Repo.all()

      assert length(messages) == 1
    end

    test "handles list-id header typical of mailing lists", %{conn: conn, mailbox: mailbox} do
      params = %{
        "from" => "user@example.com",
        "to" => "linux-kernel@vger.kernel.org",
        "rcpt_to" => "edgecase@elektrine.com",
        "subject" => "[PATCH] Fix something",
        "text_body" => "Patch content here",
        "list_id" => "<linux-kernel.vger.kernel.org>",
        "message_id" => "test-list-id-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      import Ecto.Query

      messages =
        Elektrine.Email.Message
        |> where(mailbox_id: ^mailbox.id)
        |> Elektrine.Repo.all()

      assert length(messages) == 1
    end
  end

  describe "plus addressing with mailing lists" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "plususer@elektrine.com"})
      {:ok, user: user, mailbox: mailbox}
    end

    test "handles plus addressing in rcpt_to with mailing list to header", %{
      conn: conn,
      mailbox: mailbox
    } do
      params = %{
        "from" => "sender@lists.example.org",
        "to" => "list@lists.example.org",
        "rcpt_to" => "plususer+listname@elektrine.com",
        "subject" => "Plus addressing test",
        "text_body" => "Test content",
        "message_id" => "test-plus-#{System.system_time(:millisecond)}"
      }

      conn =
        conn
        |> auth_conn()
        |> post(~p"/api/haraka/inbound", params)

      assert json_response(conn, 200)["status"] == "success"

      messages = Email.list_inbox_messages(mailbox.id)
      assert length(messages) == 1
    end
  end

  describe "domains endpoint" do
    test "returns built-in domains", %{conn: conn} do
      conn =
        conn
        |> auth_conn()
        |> get(~p"/api/haraka/domains")

      response = json_response(conn, 200)
      assert is_list(response["domains"])
      # Should include built-in domains
      assert "elektrine.com" in response["domains"]
      assert "z.org" in response["domains"]
    end

    test "rejects request without API key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> get(~p"/api/haraka/domains")

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end
  end
end
