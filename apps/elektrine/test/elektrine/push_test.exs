defmodule Elektrine.PushTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.{AccountsFixtures, Push, Repo}
  alias Elektrine.Push.DeviceToken
  alias Elektrine.Secrets.EncryptedString

  defmodule ConnectedPresence do
    def get_by_key("mobile:users", "123"), do: [%{metas: [%{user_id: 123}]}]
    def get_by_key(_topic, _key), do: []
  end

  defmodule UnavailablePresence do
    def get_by_key(_topic, _key) do
      raise ArgumentError, "the table identifier does not refer to an existing ETS table"
    end
  end

  test "returns false when web runtime component is disabled" do
    refute Push.user_has_active_connection?(123,
             web_enabled?: false,
             presence_running?: true,
             presence_module: ConnectedPresence
           )
  end

  test "returns false when the presence process is not running" do
    refute Push.user_has_active_connection?(123,
             web_enabled?: true,
             presence_running?: false,
             presence_module: ConnectedPresence
           )
  end

  test "returns false when the presence tracker ETS table is unavailable" do
    refute Push.user_has_active_connection?(123,
             web_enabled?: true,
             presence_running?: true,
             presence_module: UnavailablePresence
           )
  end

  test "returns true when presence lookup finds an active connection" do
    assert Push.user_has_active_connection?(123,
             web_enabled?: true,
             presence_running?: true,
             presence_module: ConnectedPresence
           )
  end

  test "register_device stores encrypted token and lookup hash" do
    user = AccountsFixtures.user_fixture()
    token = "ExponentPushToken[abc123]"

    assert {:ok, device} =
             Push.register_device(user.id, %{
               token: token,
               platform: "android",
               device_name: "Pixel"
             })

    assert device.token == token
    assert device.token_hash == Push.device_token_hash(token)

    [[stored_token, stored_token_hash]] =
      Repo.query!("SELECT token, token_hash FROM device_tokens WHERE id = $1", [device.id]).rows

    assert EncryptedString.encrypted?(stored_token)
    refute stored_token == token
    assert stored_token_hash == Push.device_token_hash(token)
    assert Push.get_device_by_token(token).id == device.id
  end

  test "register_device updates existing devices by token hash" do
    user = AccountsFixtures.user_fixture()
    token = "ExponentPushToken[update-me]"

    assert {:ok, first} = Push.register_device(user.id, %{token: token, platform: "android"})

    assert {:ok, second} =
             Push.register_device(user.id, %{
               token: token,
               platform: "android",
               device_name: "Updated"
             })

    assert second.id == first.id
    assert second.device_name == "Updated"
    assert Repo.aggregate(DeviceToken, :count) == 1
  end

  test "unregister_device deletes by token hash" do
    user = AccountsFixtures.user_fixture()
    token = "ExponentPushToken[delete-me]"

    assert {:ok, device} = Push.register_device(user.id, %{token: token, platform: "android"})
    assert {:ok, _deleted} = Push.unregister_device(token)
    refute Repo.get(DeviceToken, device.id)
  end
end
