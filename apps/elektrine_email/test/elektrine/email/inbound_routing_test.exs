defmodule Elektrine.Email.InboundRoutingTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures
  import Elektrine.EmailFixtures

  alias Elektrine.Email
  alias Elektrine.Email.InboundRouting

  describe "resolve_recipient_mailbox/2" do
    test "prefers rcpt_to for mailing list style deliveries" do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "routeuser@elektrine.com"})

      assert {:ok, resolved_mailbox} =
               InboundRouting.resolve_recipient_mailbox(
                 "debian-user@lists.debian.org",
                 "routeuser@elektrine.com"
               )

      assert resolved_mailbox.id == mailbox.id
    end

    test "resolves plus addressing to the base mailbox" do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "plusroute@elektrine.com"})

      assert {:ok, resolved_mailbox} =
               InboundRouting.resolve_recipient_mailbox(
                 "news@lists.example.org",
                 "plusroute+tag@elektrine.com"
               )

      assert resolved_mailbox.id == mailbox.id
    end

    test "returns forwarding tuple for aliases with external targets" do
      user = user_fixture()
      local_part = "aliasroute#{System.unique_integer([:positive])}"
      alias_email = "#{local_part}@elektrine.com"

      assert {:ok, _alias} =
               Email.create_alias(%{
                 username: local_part,
                 domain: "elektrine.com",
                 target_email: "target@example.net",
                 user_id: user.id
               })

      assert {:forward_external, "target@example.net", ^alias_email} =
               InboundRouting.resolve_recipient_mailbox(alias_email, alias_email)
    end
  end

  describe "validate_mailbox_route/3" do
    test "rejects mismatched recipient to mailbox routing" do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "owner@elektrine.com"})

      assert {:error, reason} =
               InboundRouting.validate_mailbox_route(
                 "other@elektrine.com",
                 "other@elektrine.com",
                 mailbox
               )

      assert reason =~ "Email address mismatch"
    end
  end

  describe "routing classification" do
    test "outbound_email?/2 identifies local -> external envelopes" do
      assert InboundRouting.outbound_email?("user@elektrine.com", "friend@example.com")
      refute InboundRouting.outbound_email?("user@elektrine.com", "friend@z.org")
      refute InboundRouting.outbound_email?("sender@example.com", "user@elektrine.com")
    end

    test "loopback_email?/3 detects recent sent-message loopbacks" do
      sender_user = user_fixture()
      {:ok, sender_mailbox} = Email.ensure_user_has_mailbox(sender_user)

      recipient_user = user_fixture()
      {:ok, recipient_mailbox} = Email.ensure_user_has_mailbox(recipient_user)

      assert {:ok, _sent} =
               Email.create_message(%{
                 message_id: "loopback-#{System.unique_integer([:positive])}",
                 mailbox_id: sender_mailbox.id,
                 from: sender_mailbox.email,
                 to: recipient_mailbox.email,
                 subject: "Loopback Subject",
                 status: "sent"
               })

      assert InboundRouting.loopback_email?(
               sender_mailbox.email,
               recipient_mailbox.email,
               "Loopback Subject"
             )
    end
  end
end
