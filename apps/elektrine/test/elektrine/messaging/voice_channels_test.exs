defmodule Elektrine.Messaging.VoiceChannelsTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias Elektrine.Messaging.ChatConversation
  alias Elektrine.Messaging.ChatConversationMember
  alias Elektrine.Messaging.Federation.Visibility
  alias Elektrine.Messaging.Server
  alias Elektrine.Messaging.VoiceChannels
  alias Elektrine.Repo

  defp create_server_with_owner do
    owner = AccountsFixtures.user_fixture()

    {:ok, server} =
      Messaging.create_server(owner.id, %{name: "voice-hub", is_public: true})

    %{owner: owner, server: server}
  end

  describe "voice channel creation" do
    test "creates a voice channel inside a server and adds all members" do
      %{owner: owner, server: server} = create_server_with_owner()
      joiner = AccountsFixtures.user_fixture()
      {:ok, _member} = Messaging.join_server(server.id, joiner.id)

      assert {:ok, channel} =
               Messaging.create_server_channel(server.id, owner.id, %{
                 name: "hangout",
                 type: "voice_channel"
               })

      assert channel.type == "voice_channel"
      assert channel.server_id == server.id
      assert Messaging.get_conversation_member(channel.id, owner.id)
      assert Messaging.get_conversation_member(channel.id, joiner.id)
    end

    test "voice channels share the channel position sequence" do
      %{owner: owner, server: server} = create_server_with_owner()

      assert {:ok, voice} =
               Messaging.create_server_channel(server.id, owner.id, %{
                 name: "hangout",
                 type: "voice_channel"
               })

      assert {:ok, text} =
               Messaging.create_server_channel(server.id, owner.id, %{name: "random"})

      assert text.type == "channel"
      assert text.channel_position > voice.channel_position
    end

    test "plain members cannot create voice channels" do
      %{server: server} = create_server_with_owner()
      member = AccountsFixtures.user_fixture()
      {:ok, _member} = Messaging.join_server(server.id, member.id)

      assert {:error, :unauthorized} =
               Messaging.create_server_channel(server.id, member.id, %{
                 name: "hangout",
                 type: "voice_channel"
               })
    end

    test "new server members are added to existing voice channels" do
      %{owner: owner, server: server} = create_server_with_owner()

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "hangout",
          type: "voice_channel"
        })

      late_joiner = AccountsFixtures.user_fixture()
      {:ok, _member} = Messaging.join_server(server.id, late_joiner.id)

      assert Messaging.get_conversation_member(channel.id, late_joiner.id)
    end
  end

  describe "type validation" do
    test "accepts the voice_channel type" do
      changeset =
        ChatConversation.changeset(%ChatConversation{}, %{
          type: "voice_channel",
          name: "hangout"
        })

      assert changeset.valid?
    end

    test "rejects unknown types" do
      changeset =
        ChatConversation.changeset(%ChatConversation{}, %{type: "video_stage", name: "nope"})

      refute changeset.valid?
      assert %{type: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "authorize_join/2" do
    setup do
      %{owner: owner, server: server} = create_server_with_owner()

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "hangout",
          type: "voice_channel"
        })

      %{owner: owner, server: server, channel: channel}
    end

    test "allows active members", %{owner: owner, channel: channel} do
      assert :ok = VoiceChannels.authorize_join(channel.id, owner.id)
    end

    test "rejects users who are not members", %{channel: channel} do
      outsider = AccountsFixtures.user_fixture()

      assert {:error, :unauthorized} = VoiceChannels.authorize_join(channel.id, outsider.id)
    end

    test "rejects text channels", %{owner: owner, server: server} do
      {:ok, server_with_channels} = Messaging.get_server(server.id, owner.id)
      text_channel = Enum.find(server_with_channels.channels, &(&1.type == "channel"))

      assert {:error, :not_found} = VoiceChannels.authorize_join(text_channel.id, owner.id)
    end

    test "rejects mirrored voice channels" do
      user = AccountsFixtures.user_fixture()

      mirror_server =
        %Server{}
        |> Server.changeset(%{
          name: "remote-hub",
          is_public: true,
          federation_id: "https://remote.example/_arblarg/servers/9",
          origin_domain: "remote.example",
          is_federated_mirror: true
        })
        |> Repo.insert!()

      mirror_channel =
        %ChatConversation{}
        |> ChatConversation.voice_channel_changeset(%{
          name: "remote-voice",
          server_id: mirror_server.id,
          is_federated_mirror: true,
          federated_source: "https://remote.example/_arblarg/channels/10"
        })
        |> Repo.insert!()

      ChatConversationMember.add_member_changeset(mirror_channel.id, user.id, "member")
      |> Repo.insert!()

      assert {:error, :remote_mirror} = VoiceChannels.authorize_join(mirror_channel.id, user.id)
    end
  end

  describe "check_capacity/2" do
    test "allows joins below the cap" do
      assert :ok = VoiceChannels.check_capacity([1, 2, 3], 4)
    end

    test "rejects joins at the cap" do
      occupants = Enum.to_list(1..VoiceChannels.max_occupants())

      assert {:error, :channel_full} =
               VoiceChannels.check_capacity(occupants, VoiceChannels.max_occupants() + 1)
    end

    test "rejects duplicate joins before the cap check" do
      occupants = Enum.to_list(1..VoiceChannels.max_occupants())

      assert {:error, :already_joined} = VoiceChannels.check_capacity(occupants, 1)
      assert {:error, :already_joined} = VoiceChannels.check_capacity([7], 7)
    end

    test "defaults to eight occupants" do
      assert VoiceChannels.max_occupants() == 8
    end
  end

  describe "federation exclusion" do
    test "voice channels are not part of public bootstrap payloads" do
      %{owner: owner, server: server} = create_server_with_owner()

      {:ok, voice} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "hangout",
          type: "voice_channel"
        })

      server = Repo.get!(Server, server.id)
      bootstrap_channels = Visibility.public_bootstrap_channels(server)

      assert Enum.any?(bootstrap_channels, &(&1.type == "channel"))
      refute Enum.any?(bootstrap_channels, &(&1.id == voice.id))
    end
  end
end
