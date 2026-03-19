defmodule Elektrine.Email.PlatformEmailHeadersTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures
  import Swoosh.TestAssertions

  alias Elektrine.Email.Sender
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
end
