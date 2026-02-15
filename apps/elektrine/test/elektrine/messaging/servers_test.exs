defmodule Elektrine.Messaging.ServersTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging

  describe "create_server/2" do
    test "creates a server with a default general channel" do
      owner = AccountsFixtures.user_fixture()

      assert {:ok, server} =
               Messaging.create_server(owner.id, %{
                 name: "engineering",
                 description: "Engineering team space"
               })

      assert server.name == "engineering"
      assert length(server.channels) == 1

      [default_channel] = server.channels
      assert default_channel.name == "general"
      assert default_channel.type == "channel"
      assert default_channel.server_id == server.id

      assert %{role: "owner"} = Messaging.get_server_member(server.id, owner.id)
      default_channel_id = default_channel.id

      assert %{conversation_id: ^default_channel_id} =
               Messaging.get_conversation_member(default_channel.id, owner.id)
    end
  end

  describe "join_server/2" do
    test "joins a public server and adds membership to server channels" do
      owner = AccountsFixtures.user_fixture()
      joiner = AccountsFixtures.user_fixture()

      assert {:ok, server} =
               Messaging.create_server(owner.id, %{
                 name: "public-hub",
                 is_public: true
               })

      assert {:ok, _member} = Messaging.join_server(server.id, joiner.id)
      assert %{role: "member"} = Messaging.get_server_member(server.id, joiner.id)

      {:ok, joined_server} = Messaging.get_server(server.id, joiner.id)

      assert Enum.all?(
               joined_server.channels,
               &Messaging.get_conversation_member(&1.id, joiner.id)
             )
    end
  end

  describe "create_server_channel/3" do
    test "owner can create channels in a server" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "owner-space"})

      assert {:ok, channel} =
               Messaging.create_server_channel(server.id, owner.id, %{
                 name: "ops",
                 description: "Operations channel"
               })

      assert channel.name == "ops"
      assert channel.server_id == server.id
      assert channel.type == "channel"
      assert Messaging.get_conversation_member(channel.id, owner.id)
    end

    test "regular members cannot create channels" do
      owner = AccountsFixtures.user_fixture()
      member = AccountsFixtures.user_fixture()

      {:ok, server} = Messaging.create_server(owner.id, %{name: "permissions", is_public: true})
      {:ok, _} = Messaging.join_server(server.id, member.id)

      assert {:error, :unauthorized} =
               Messaging.create_server_channel(server.id, member.id, %{name: "restricted"})
    end
  end
end
