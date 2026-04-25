defmodule Elektrine.Email.InboundRoutingTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures
  import Elektrine.EmailFixtures

  alias Elektrine.Domains
  alias Elektrine.Email
  alias Elektrine.Email.InboundRouting

  describe "resolve_recipient_mailbox/2" do
    test "prefers rcpt_to for mailing list style deliveries" do
      user = user_fixture()

      mailbox =
        mailbox_fixture(%{user_id: user.id, email: "routeuser@#{Domains.primary_email_domain()}"})

      assert {:ok, resolved_mailbox} =
               InboundRouting.resolve_recipient_mailbox(
                 "debian-user@lists.debian.org",
                 "routeuser@#{Domains.primary_email_domain()}"
               )

      assert resolved_mailbox.id == mailbox.id
    end

    test "resolves plus addressing to the base mailbox" do
      user = user_fixture()

      mailbox =
        mailbox_fixture(%{user_id: user.id, email: "plusroute@#{Domains.primary_email_domain()}"})

      assert {:ok, resolved_mailbox} =
               InboundRouting.resolve_recipient_mailbox(
                 "news@lists.example.org",
                 "plusroute+tag@#{Domains.primary_email_domain()}"
               )

      assert resolved_mailbox.id == mailbox.id
    end

    test "resolves supported cross-domain recipient to the same mailbox" do
      user = user_fixture()

      mailbox =
        mailbox_fixture(%{
          user_id: user.id,
          email: "crossroute@#{Domains.primary_email_domain()}"
        })

      assert {:ok, resolved_mailbox} =
               InboundRouting.resolve_recipient_mailbox(
                 "crossroute@#{Domains.primary_email_domain()}",
                 "crossroute@#{Domains.primary_email_domain()}"
               )

      assert resolved_mailbox.id == mailbox.id
    end

    test "returns forwarding tuple for aliases with external targets" do
      user = user_fixture()
      local_part = "aliasroute#{System.unique_integer([:positive])}"
      alias_email = "#{local_part}@#{Domains.primary_email_domain()}"

      assert {:ok, _alias} =
               Email.create_alias(%{
                 username: local_part,
                 domain: Domains.primary_email_domain(),
                 target_email: "target@example.net",
                 user_id: user.id
               })

      assert {:forward_external, "target@example.net", ^alias_email} =
               InboundRouting.resolve_recipient_mailbox(alias_email, alias_email)
    end

    test "routes catch-all aliases to the owner's mailbox and records usage" do
      user = user_fixture()
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
      domain = "catchroute#{System.unique_integer([:positive])}.example.net"

      {:ok, custom_domain} = Email.create_custom_domain(user, %{"domain" => domain})

      custom_domain
      |> Ecto.Changeset.change(
        status: "verified",
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> Elektrine.Repo.update!()

      assert {:ok, alias_record} =
               Email.create_alias(%{
                 alias_email: "*@#{domain}",
                 catch_all: true,
                 delivery_mode: "deliver",
                 auto_label: "catch-all",
                 user_id: user.id
               })

      recipient = "shopping#{System.unique_integer([:positive])}@#{domain}"

      assert {:ok, resolved_mailbox} =
               InboundRouting.resolve_recipient_mailbox(recipient, recipient)

      assert resolved_mailbox.id == mailbox.id

      refetched = Email.get_alias(alias_record.id, user.id)
      assert refetched.received_count == 1
      assert refetched.forwarded_count == 0
      assert refetched.last_used_at
    end

    test "expired temporary aliases stop accepting unmatched recipients" do
      user = user_fixture()
      domain = Domains.primary_email_domain()

      assert {:ok, _alias_record} =
               Email.create_alias(%{
                 alias_email: "burner#{System.unique_integer([:positive])}@#{domain}",
                 delivery_mode: "deliver",
                 expires_at:
                   DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second),
                 user_id: user.id
               })

      alias_email = Email.list_aliases(user.id) |> hd() |> Map.fetch!(:alias_email)

      assert {:error, :no_mailbox} =
               InboundRouting.resolve_recipient_mailbox(alias_email, alias_email)
    end

    test "resolves verified custom-domain recipients to the owner's mailbox" do
      user = user_fixture(%{username: "customroute"})
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

      {:ok, custom_domain} =
        Email.create_custom_domain(user, %{"domain" => "mail.customroute.test"})

      assert {:ok, _verified_domain} =
               custom_domain
               |> Ecto.Changeset.change(
                 status: "verified",
                 verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
               )
               |> Elektrine.Repo.update()

      assert {:ok, resolved_mailbox} =
               InboundRouting.resolve_recipient_mailbox(
                 "customroute@mail.customroute.test",
                 "customroute@mail.customroute.test"
               )

      assert resolved_mailbox.id == mailbox.id
    end
  end

  describe "validate_mailbox_route/3" do
    test "accepts supported cross-domain recipient for mailbox" do
      user = user_fixture()

      mailbox =
        mailbox_fixture(%{user_id: user.id, email: "owner@#{Domains.primary_email_domain()}"})

      assert :ok =
               InboundRouting.validate_mailbox_route(
                 "list@lists.example.org",
                 "owner@#{Domains.primary_email_domain()}",
                 mailbox
               )
    end

    test "rejects mismatched recipient to mailbox routing" do
      user = user_fixture()

      mailbox =
        mailbox_fixture(%{user_id: user.id, email: "owner@#{Domains.primary_email_domain()}"})

      assert {:error, reason} =
               InboundRouting.validate_mailbox_route(
                 "other@example.net",
                 "other@example.net",
                 mailbox
               )

      assert reason =~ "Email address mismatch"
    end
  end

  describe "routing classification" do
    test "outbound_email?/2 identifies local -> external envelopes" do
      local = "user@#{Domains.primary_email_domain()}"

      assert InboundRouting.outbound_email?(local, "friend@example.net")
      refute InboundRouting.outbound_email?("user@example.net", "friend@example.org")
      refute InboundRouting.outbound_email?("sender@example.net", local)
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
