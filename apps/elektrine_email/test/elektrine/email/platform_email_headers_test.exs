defmodule Elektrine.Email.PlatformEmailHeadersTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures
  import Swoosh.TestAssertions

  alias Elektrine.Email
  alias Elektrine.Email.Sender
  alias Elektrine.Email.Unsubscribes
  alias Elektrine.EmailAddresses

  setup :set_swoosh_global

  test "vpn quota warning emails use the account list id" do
    user = user_fixture()

    user_config = %{
      bandwidth_quota_bytes: 100 * 1_073_741_824,
      quota_used_bytes: 85 * 1_073_741_824,
      quota_period_start: DateTime.utc_now() |> DateTime.truncate(:second),
      vpn_server: %{name: "Test VPN"}
    }

    assert {:ok, _response} = Sender.send_vpn_quota_warning(user, user_config, 85)
    assert_received {:email, email}

    assert Map.get(email.headers, "List-Id") ==
             EmailAddresses.list_id("elektrine-account")
  end

  test "vpn quota suspension emails use the account list id" do
    user = user_fixture()

    user_config = %{
      bandwidth_quota_bytes: 100 * 1_073_741_824,
      quota_used_bytes: 110 * 1_073_741_824,
      quota_period_start: DateTime.utc_now() |> DateTime.truncate(:second),
      vpn_server: %{name: "Test VPN"}
    }

    assert {:ok, _response} = Sender.send_vpn_quota_suspended(user, user_config)
    assert_received {:email, email}

    assert Map.get(email.headers, "List-Id") ==
             EmailAddresses.list_id("elektrine-account")
  end

  test "mass email adds verifiable unsubscribe headers" do
    user = user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

    assert {:ok, _response} =
             Sender.send_email(user.id, %{
               from: mailbox.email,
               to: "reader@example.com",
               subject: "Newsletter",
               text_body: "hello",
               list_id: "elektrine-newsletter"
             })

    assert_received {:email, email}
    unsubscribe_header = Map.fetch!(email.headers, "List-Unsubscribe")
    assert Map.get(email.headers, "List-Unsubscribe-Post") == "List-Unsubscribe=One-Click"
    assert Map.get(email.headers, "List-Id") == EmailAddresses.list_id("elektrine-newsletter")

    [_, token] = Regex.run(~r{/unsubscribe/([^>]+)}, unsubscribe_header)

    assert {:ok, %{email: "reader@example.com", list_id: "elektrine-newsletter"}} =
             Unsubscribes.verify_token(token)
  end

  test "mass email with multiple recipients is split for recipient-specific unsubscribe tokens" do
    user = user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

    assert {:ok, %{sent_count: 2}} =
             Sender.send_email(user.id, %{
               from: mailbox.email,
               to: "first@example.com, second@example.com",
               subject: "Newsletter",
               text_body: "hello",
               list_id: "elektrine-newsletter"
             })

    sent_messages =
      mailbox.id
      |> Email.list_messages(20, 0)
      |> Enum.filter(&(&1.subject == "Newsletter"))

    assert Enum.map(sent_messages, & &1.to) |> Enum.sort() == [
             "first@example.com",
             "second@example.com"
           ]
  end
end
