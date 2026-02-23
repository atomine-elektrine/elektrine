defmodule Elektrine.Messaging.ServersTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Server
  alias Elektrine.Repo

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
      assert default_channel.is_public

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
      assert channel.is_public
      assert Messaging.get_conversation_member(channel.id, owner.id)
    end

    test "owner can create private channels in a server" do
      owner = AccountsFixtures.user_fixture()
      {:ok, server} = Messaging.create_server(owner.id, %{name: "owner-space"})

      assert {:ok, channel} =
               Messaging.create_server_channel(server.id, owner.id, %{
                 name: "leadership",
                 description: "Private planning",
                 is_public: false
               })

      assert channel.name == "leadership"
      refute channel.is_public
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

  describe "list_public_servers/2" do
    test "returns joinable public servers including federated mirrors" do
      owner = AccountsFixtures.user_fixture()
      discoverer = AccountsFixtures.user_fixture()

      {:ok, joined_server} = Messaging.create_server(owner.id, %{name: "joined", is_public: true})
      {:ok, _} = Messaging.join_server(joined_server.id, discoverer.id)

      {:ok, public_local_server} =
        Messaging.create_server(owner.id, %{name: "public-local", is_public: true})

      {:ok, _private_server} =
        Messaging.create_server(owner.id, %{name: "private-local", is_public: false})

      {:ok, federated_server} =
        %Server{}
        |> Server.changeset(%{
          name: "remote-hub",
          description: "Federated remote server",
          is_public: true,
          member_count: 42,
          federation_id: "https://remote.example/federation/messaging/servers/77",
          origin_domain: "remote.example",
          is_federated_mirror: true
        })
        |> Repo.insert()

      servers = Messaging.list_public_servers(discoverer.id)
      server_ids = MapSet.new(Enum.map(servers, & &1.id))

      assert MapSet.member?(server_ids, public_local_server.id)
      assert MapSet.member?(server_ids, federated_server.id)
      refute MapSet.member?(server_ids, joined_server.id)
    end

    test "supports search query matching name, description, and origin domain" do
      owner = AccountsFixtures.user_fixture()
      discoverer = AccountsFixtures.user_fixture()

      {:ok, _local_server} =
        Messaging.create_server(owner.id, %{
          name: "artists",
          description: "creative hangout",
          is_public: true
        })

      {:ok, _remote_server} =
        %Server{}
        |> Server.changeset(%{
          name: "federated-devs",
          description: "dev community",
          is_public: true,
          member_count: 12,
          federation_id: "https://federated.example/federation/messaging/servers/19",
          origin_domain: "federated.example",
          is_federated_mirror: true
        })
        |> Repo.insert()

      assert ["artists"] ==
               discoverer.id
               |> Messaging.list_public_servers(query: "creative")
               |> Enum.map(& &1.name)

      assert ["federated-devs"] ==
               discoverer.id
               |> Messaging.list_public_servers(query: "federated.example")
               |> Enum.map(& &1.name)
    end

    test "imports remote discovery entries into mirror servers" do
      discoverer = AccountsFixtures.user_fixture()

      remote_discovery = [
        %{
          "name" => "remote-discovery",
          "description" => "Remote discoverable server",
          "is_public" => true,
          "member_count" => 21,
          "origin_domain" => "remote.example",
          "federation_id" => "https://remote.example/federation/messaging/servers/212"
        }
      ]

      servers =
        Messaging.list_public_servers(discoverer.id,
          remote_discovery_fn: fn _query, _limit -> remote_discovery end
        )

      assert Enum.any?(
               servers,
               &(&1.federation_id == "https://remote.example/federation/messaging/servers/212")
             )

      mirror =
        Repo.get_by(Server,
          federation_id: "https://remote.example/federation/messaging/servers/212"
        )

      assert mirror
      assert mirror.is_federated_mirror
      assert mirror.origin_domain == "remote.example"
      assert mirror.member_count == 21
    end
  end
end
