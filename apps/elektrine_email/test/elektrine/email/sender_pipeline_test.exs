defmodule Elektrine.Email.SenderPipelineTest do
  use Elektrine.DataCase

  alias Atomine.Credits
  alias Elektrine.Accounts
  alias Elektrine.Email
  alias Elektrine.Email.CustomDomain
  alias Elektrine.Email.Sender
  alias Elektrine.Notifications
  alias Elektrine.Repo
  import Swoosh.TestAssertions

  setup :set_swoosh_global

  describe "outbound pipeline boundaries" do
    setup do
      sender_username = unique_username("sender")
      recipient_username = unique_username("recipient")

      {:ok, sender} =
        Accounts.create_user(%{
          username: sender_username,
          password: "SenderPipeline123!",
          password_confirmation: "SenderPipeline123!"
        })

      {:ok, recipient} =
        Accounts.create_user(%{
          username: recipient_username,
          password: "RecipientPipeline123!",
          password_confirmation: "RecipientPipeline123!"
        })

      {:ok, sender_mailbox} = Email.ensure_user_has_mailbox(sender)
      {:ok, recipient_mailbox} = Email.ensure_user_has_mailbox(recipient)
      assert {:ok, _ledger_entry} = Credits.grant(sender.id, :atomine_credit, 10, "test_grant")

      %{
        sender: sender,
        sender_mailbox: sender_mailbox,
        recipient_mailbox: recipient_mailbox
      }
    end

    test "parses raw SMTP data then sanitizes subject/body once", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      raw_email =
        [
          "From: #{sender_mailbox.email}",
          "To: #{recipient_mailbox.email}",
          "Subject: Hello",
          "\tBcc: attacker@example.com",
          "MIME-Version: 1.0",
          "Content-Type: text/html; charset=UTF-8",
          "",
          "<script>alert('x')</script><p>Hello</p>"
        ]
        |> Enum.join("\r\n")

      params = %{
        from: sender_mailbox.email,
        to: recipient_mailbox.email,
        raw_email: raw_email
      }

      assert {:ok, sent_message} = Sender.send_email(sender.id, params)
      assert sent_message.subject == "Hello Bcc: attacker@example.com"
      refute sent_message.subject =~ ~r/[\r\n]/

      sanitized_body = sent_message.html_body || sent_message.text_body || ""
      refute sanitized_body =~ "<script"
      assert sanitized_body =~ "Hello"
    end

    test "keeps raw SMTP body when MIME parsing finds no display body", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      raw_email =
        [
          "From: #{sender_mailbox.email}",
          "To: #{recipient_mailbox.email}",
          "Subject: Body fallback",
          "MIME-Version: 1.0",
          "X-Client: Thunderbird",
          "",
          "Hello from Thunderbird fallback"
        ]
        |> Enum.join("\r\n")

      assert {:ok, _sent_message} =
               Sender.send_email(sender.id, %{
                 from: sender_mailbox.email,
                 to: recipient_mailbox.email,
                 raw_email: raw_email
               })

      received_message =
        recipient_mailbox.id
        |> Email.list_messages(50, 0)
        |> Enum.find(&(&1.subject == "Body fallback" && &1.status == "received"))
        |> then(&Email.get_message(&1.id, recipient_mailbox.id))

      assert received_message.text_body == "Hello from Thunderbird fallback"
    end

    test "deduplicates duplicate Thunderbird internal recipients by Message-ID", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      raw_email =
        [
          "From: #{sender_mailbox.email}",
          "To: #{recipient_mailbox.email}",
          "Subject: Thunderbird internal duplicate",
          "Message-ID: <thunderbird-internal-duplicate@example.com>",
          "MIME-Version: 1.0",
          "Content-Type: text/plain; charset=UTF-8",
          "",
          "Hello once"
        ]
        |> Enum.join("\r\n")

      assert {:ok, _sent_message} =
               Sender.send_email(sender.id, %{
                 from: sender_mailbox.email,
                 to: "#{recipient_mailbox.email}, #{recipient_mailbox.email}",
                 raw_email: raw_email
               })

      received_messages =
        recipient_mailbox.id
        |> Email.list_messages(50, 0)
        |> Enum.filter(
          &(&1.subject == "Thunderbird internal duplicate" && &1.status == "received")
        )

      assert [received_message] = received_messages
      assert received_message.message_id == "thunderbird-internal-duplicate@example.com"
    end

    test "internal delivery shares the sent copy's Message-ID with the recipient copy", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      # Webmail compose does not set a Message-ID, so without reconciliation the sent
      # and received copies get different IDs. The recipient's reply then points
      # In-Reply-To at an ID the sender's mailbox never stored, orphaning the
      # conversation starter from the thread. Both copies must share one Message-ID.
      assert {:ok, _result} =
               Sender.send_email(sender.id, %{
                 from: sender_mailbox.email,
                 to: recipient_mailbox.email,
                 subject: "Internal threading starter",
                 text_body: "Kick off the conversation"
               })

      sent_message =
        sender_mailbox.id
        |> Email.list_messages(50, 0)
        |> Enum.find(&(&1.subject == "Internal threading starter" && &1.status == "sent"))

      received_message =
        recipient_mailbox.id
        |> Email.list_messages(50, 0)
        |> Enum.find(&(&1.subject == "Internal threading starter" && &1.status == "received"))

      assert sent_message
      assert received_message
      assert sent_message.message_id
      assert sent_message.message_id == received_message.message_id
    end

    test "hides BCC recipients from every internal recipient copy", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      {:ok, blind_recipient} =
        Accounts.create_user(%{
          username: unique_username("blind"),
          password: "BlindRecipient123!",
          password_confirmation: "BlindRecipient123!"
        })

      {:ok, blind_mailbox} = Email.ensure_user_has_mailbox(blind_recipient)

      assert {:ok, sent_message} =
               Sender.send_email(sender.id, %{
                 from: sender_mailbox.email,
                 to: recipient_mailbox.email,
                 bcc: blind_mailbox.email,
                 subject: "Private blind recipient",
                 text_body: "The BCC list must remain private"
               })

      regular_copy =
        recipient_mailbox.id
        |> Email.list_messages(50, 0)
        |> Enum.find(&(&1.subject == "Private blind recipient" && &1.status == "received"))

      blind_copy =
        blind_mailbox.id
        |> Email.list_messages(50, 0)
        |> Enum.find(&(&1.subject == "Private blind recipient" && &1.status == "received"))

      assert sent_message.bcc == blind_mailbox.email
      assert regular_copy.bcc == nil
      assert blind_copy.bcc == nil
    end

    test "deduplicates internal recipients with different display names", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      assert {:ok, _sender} = Accounts.update_user(sender, %{display_name: "MAXFIELD LUKE"})

      raw_email =
        [
          "From: MAXFIELD <#{sender_mailbox.email}>",
          "To: MAXFIELD <#{recipient_mailbox.email}>, MAXFIELD LUKE <#{recipient_mailbox.email}>",
          "Subject: Thunderbird display-name duplicate",
          "Message-ID: <thunderbird-display-name-duplicate@example.com>",
          "MIME-Version: 1.0",
          "Content-Type: text/plain; charset=UTF-8",
          "",
          "Hello once"
        ]
        |> Enum.join("\r\n")

      assert {:ok, sent_message} =
               Sender.send_email(sender.id, %{
                 from: sender_mailbox.email,
                 to:
                   "MAXFIELD <#{recipient_mailbox.email}>, MAXFIELD LUKE <#{recipient_mailbox.email}>",
                 raw_email: raw_email
               })

      received_messages =
        recipient_mailbox.id
        |> Email.list_messages(50, 0)
        |> Enum.filter(
          &(&1.subject == "Thunderbird display-name duplicate" && &1.status == "received")
        )

      assert [received_message] = received_messages
      assert sent_message.from == "MAXFIELD <#{sender_mailbox.email}>"
      assert received_message.from == "MAXFIELD <#{sender_mailbox.email}>"
      assert [_delivery] = Email.list_internal_deliveries_for_message(sent_message.id)
    end

    test "does not preserve spoofed client From header when owned address appears only in display name",
         %{
           sender: sender,
           sender_mailbox: sender_mailbox,
           recipient_mailbox: recipient_mailbox
         } do
      spoofed_from = "\"Trusted <#{sender_mailbox.email}>\" <admin@example.com>"

      raw_email =
        [
          "From: #{spoofed_from}",
          "To: #{recipient_mailbox.email}",
          "Subject: Spoof attempt",
          "MIME-Version: 1.0",
          "Content-Type: text/plain; charset=UTF-8",
          "",
          "Hello"
        ]
        |> Enum.join("\r\n")

      assert {:ok, sent_message} =
               Sender.send_email(sender.id, %{
                 from: sender_mailbox.email,
                 to: recipient_mailbox.email,
                 raw_email: raw_email
               })

      refute sent_message.from == spoofed_from
      assert sent_message.from =~ sender_mailbox.email
    end

    test "filters suppressed external recipients before routing", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      assert {:ok, _suppression} =
               Email.suppress_recipient(sender.id, "blocked@example.com",
                 reason: "hard_bounce",
                 source: "test"
               )

      params = %{
        from: sender_mailbox.email,
        to: "#{recipient_mailbox.email}, blocked@example.com",
        subject: "Suppression filter",
        text_body: "hello"
      }

      assert {:ok, sent_message} = Sender.send_email(sender.id, params)
      assert sent_message.to == recipient_mailbox.email
      refute String.contains?(sent_message.to, "blocked@example.com")
    end

    test "delivers internal recipients locally while preserving external cc delivery", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      params = %{
        from: sender_mailbox.email,
        to: recipient_mailbox.email,
        cc: "outside@example.com",
        subject: "Mixed internal and external recipients",
        text_body: "hello"
      }

      assert {:ok, %{status: "queued", id: sent_id}} = Sender.send_email(sender.id, params)

      recipient_messages = Email.list_messages(recipient_mailbox.id, 50, 0)

      assert Enum.any?(
               recipient_messages,
               &(&1.subject == "Mixed internal and external recipients")
             )

      assert [internal_delivery] = Email.list_internal_deliveries_for_message(sent_id)
      assert internal_delivery.status == "delivered"
      assert internal_delivery.recipient == recipient_mailbox.email
      assert Email.internal_delivery_summary(sent_id) == %{"delivered" => 1}

      assert Enum.map(Email.list_internal_delivery_attempts(internal_delivery), & &1.status) == [
               "delivering",
               "delivered"
             ]

      assert_email_sent(to: "outside@example.com")
    end

    test "tracks internal delivery per recipient with attempt history", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      params = %{
        from: sender_mailbox.email,
        to: recipient_mailbox.email,
        subject: "Tracked internal delivery",
        text_body: "hello"
      }

      assert {:ok, sent_message} = Sender.send_email(sender.id, params)

      assert [delivery] = Email.list_internal_deliveries_for_message(sent_message.id)
      assert delivery.status == "delivered"
      assert delivery.recipient_type == "to"
      assert delivery.recipient == recipient_mailbox.email
      assert is_integer(delivery.delivered_message_id)

      attempts = Email.list_internal_delivery_attempts(delivery)
      assert Enum.map(attempts, & &1.status) == ["delivering", "delivered"]
      assert Email.internal_delivery_summary(sent_message.id) == %{"delivered" => 1}
    end

    test "rejects undeliverable internal recipients before storing sent copy", %{
      sender: sender,
      sender_mailbox: sender_mailbox
    } do
      domain = sender_mailbox.email |> String.split("@") |> List.last()

      params = %{
        from: sender_mailbox.email,
        to: "missing-#{System.unique_integer([:positive])}@#{domain}",
        subject: "Missing internal recipient",
        text_body: "hello"
      }

      assert {:error, :recipient_not_found} = Sender.send_email(sender.id, params)

      refute Enum.any?(
               Email.list_messages(sender_mailbox.id, 50, 0),
               &(&1.subject == "Missing internal recipient")
             )
    end

    test "rejects mixed sends with undeliverable internal recipients before external enqueue", %{
      sender: sender,
      sender_mailbox: sender_mailbox
    } do
      domain = sender_mailbox.email |> String.split("@") |> List.last()

      params = %{
        from: sender_mailbox.email,
        to: "outside@example.com",
        cc: "missing-#{System.unique_integer([:positive])}@#{domain}",
        subject: "Mixed missing internal recipient",
        text_body: "hello"
      }

      assert {:error, :recipient_not_found} = Sender.send_email(sender.id, params)

      refute_email_sent()

      refute Enum.any?(
               Email.list_messages(sender_mailbox.id, 50, 0),
               &(&1.subject == "Mixed missing internal recipient")
             )
    end

    test "deduplicates duplicate external submissions by stored sent message", %{
      sender: sender,
      sender_mailbox: sender_mailbox
    } do
      params = %{
        from: sender_mailbox.email,
        to: "outside@example.com",
        subject: "External duplicate guard",
        message_id: "external-duplicate@example.com",
        text_body: "hello",
        skip_rate_limit: true
      }

      assert {:ok, %{status: "queued", id: sent_id}} = Sender.send_email(sender.id, params)
      assert_email_sent(to: "outside@example.com", subject: "External duplicate guard")

      assert {:ok, %{status: "queued", id: ^sent_id}} = Sender.send_email(sender.id, params)
      refute_email_sent()

      assert [delivery] = Email.get_external_delivery_by_sent_message_id(sent_id)
      assert delivery.status == "sent"
      assert delivery.attempts == 1
      assert delivery.recipient == "outside@example.com"
      assert delivery.domain == "example.com"
      assert is_binary(delivery.trace_id)

      assert %{delivery: ^delivery, attempts: attempts} =
               Email.trace_external_delivery(delivery.trace_id)

      assert Enum.any?(attempts, &(&1.status == "sent"))
    end

    test "tracks external delivery per recipient with attempt history", %{
      sender: sender,
      sender_mailbox: sender_mailbox
    } do
      params = %{
        from: sender_mailbox.email,
        to: "reader@example.com",
        cc: "copy@example.net",
        subject: "External recipient tracking",
        message_id: "external-recipient-tracking@example.com",
        text_body: "hello",
        skip_rate_limit: true
      }

      assert {:ok, %{status: "queued", id: sent_id}} = Sender.send_email(sender.id, params)
      assert_email_sent(to: "reader@example.com")
      assert_email_sent(to: "copy@example.net")

      deliveries = Email.list_external_deliveries_for_message(sent_id)

      assert Enum.map(deliveries, & &1.recipient) |> Enum.sort() == [
               "copy@example.net",
               "reader@example.com"
             ]

      assert Email.external_delivery_summary(sent_id) == %{"sent" => 2}

      assert Enum.all?(deliveries, fn delivery ->
               delivery.trace_id && Email.list_external_delivery_attempts(delivery) != []
             end)

      metrics = Email.external_delivery_operational_metrics()
      assert metrics.totals["sent"] >= 2

      assert {:ok, bounced_delivery} =
               Email.mark_external_delivery_bounced_by_signal(
                 %{message_id: params.message_id, recipient: "reader@example.com"},
                 "550 user unknown"
               )

      assert bounced_delivery.status == "bounced"
    end

    test "blocks external sends from custom domains before DKIM is ready", %{
      sender: sender
    } do
      domain = "#{unique_username("mail")}.example.net"

      {:ok, _custom_domain} =
        %CustomDomain{}
        |> CustomDomain.changeset(%{
          domain: domain,
          verification_token: "token-#{System.unique_integer([:positive])}",
          status: "verified",
          verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
          user_id: sender.id
        })
        |> Repo.insert()

      assert {:error, :custom_domain_dkim_not_ready} =
               Sender.send_email(sender.id, %{
                 from: "#{sender.username}@#{domain}",
                 to: "outside@example.com",
                 subject: "Custom domain not ready",
                 text_body: "hello",
                 skip_rate_limit: true
               })

      refute_email_sent()
    end

    test "stores parsed SMTP attachments as base64-safe data", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      attachment_data = <<255, 241, 80, 64, 12, 127, 252, 1, 64, 34, 128, 163>>

      raw_email =
        [
          "From: #{sender_mailbox.email}",
          "To: #{recipient_mailbox.email}",
          "Subject: Attachment",
          "MIME-Version: 1.0",
          "Content-Type: multipart/mixed; boundary=\"outer-boundary\"",
          "",
          "--outer-boundary",
          "Content-Type: text/plain; charset=UTF-8",
          "",
          "Hello",
          "--outer-boundary",
          "Content-Type: audio/mp4; name=\"voice-note.m4a\"",
          "Content-Disposition: attachment; filename=\"voice-note.m4a\"",
          "Content-Transfer-Encoding: base64",
          "",
          Base.encode64(attachment_data),
          "--outer-boundary--",
          ""
        ]
        |> Enum.join("\r\n")

      params = %{
        from: sender_mailbox.email,
        to: recipient_mailbox.email,
        raw_email: raw_email
      }

      assert {:ok, sent_message} = Sender.send_email(sender.id, params)
      [attachment] = Map.values(sent_message.attachments)

      assert attachment["encoding"] == "base64"
      assert attachment["filename"] == "voice-note.m4a"
      assert Base.decode64!(attachment["data"]) == attachment_data
    end

    test "self-addressed mail does not create unread or notifications", %{
      sender: sender,
      sender_mailbox: sender_mailbox
    } do
      params = %{
        from: sender_mailbox.email,
        to: sender_mailbox.email,
        subject: "Note to self",
        text_body: "hello"
      }

      assert {:ok, %{status: "received"}} = Sender.send_email(sender.id, params)

      messages = Email.list_messages(sender_mailbox.id, 50, 0)
      sent_copy = Enum.find(messages, &(&1.subject == "Note to self" && &1.status == "sent"))

      received_copy =
        Enum.find(messages, &(&1.subject == "Note to self" && &1.status == "received"))

      assert sent_copy
      assert received_copy
      assert received_copy.read
      assert received_copy.metadata["self_email"]
      assert Email.unread_count(sender_mailbox.id) == 0
      assert Notifications.list_notifications(sender.id) == []
    end

    test "blocks send when every recipient is suppressed", %{
      sender: sender,
      sender_mailbox: sender_mailbox
    } do
      assert {:ok, _suppression} =
               Email.suppress_recipient(sender.id, "blocked@example.com",
                 reason: "complaint",
                 source: "test"
               )

      params = %{
        from: sender_mailbox.email,
        to: "blocked@example.com",
        subject: "Suppressed only",
        text_body: "hello"
      }

      assert {:error, reason} = Sender.send_email(sender.id, params)
      assert reason =~ "suppressed"
    end
  end

  defp unique_username(prefix) do
    "#{prefix}#{System.unique_integer([:positive])}"
  end
end
