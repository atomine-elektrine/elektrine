defmodule Elektrine.Messaging.FederationPeerPolicyTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.Messaging.Federation

  describe "runtime peer policies" do
    setup do
      original_config = Application.get_env(:elektrine, :messaging_federation, [])

      peer = %{
        domain: "remote.example",
        base_url: "https://remote.example",
        shared_secret: "test-secret",
        allow_incoming: true,
        allow_outgoing: true
      }

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.put(original_config, :peers, [peer])
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, original_config)
      end)

      :ok
    end

    test "block policy disables incoming and outgoing federation" do
      assert Federation.incoming_peer("remote.example")
      assert length(Federation.outgoing_peers()) == 1

      assert {:ok, _policy} = Federation.block_peer_domain("remote.example", "manual block")

      assert is_nil(Federation.incoming_peer("remote.example"))
      assert Federation.outgoing_peers() == []
    end

    test "directional runtime overrides affect only selected direction" do
      assert {:ok, _policy} =
               Federation.upsert_peer_policy("remote.example", %{
                 blocked: false,
                 allow_incoming: false
               })

      assert is_nil(Federation.incoming_peer("remote.example"))
      assert length(Federation.outgoing_peers()) == 1

      assert {:ok, _policy} =
               Federation.upsert_peer_policy("remote.example", %{
                 blocked: false,
                 allow_incoming: nil,
                 allow_outgoing: false
               })

      assert Federation.incoming_peer("remote.example")
      assert Federation.outgoing_peers() == []
    end

    test "peer controls include runtime-only block entries" do
      assert {:ok, _policy} = Federation.block_peer_domain("manual.example", "proactive block")

      controls = Federation.list_peer_controls()

      assert Enum.any?(controls, fn control ->
               control.domain == "manual.example" and control.configured == false and
                 control.blocked == true
             end)
    end
  end

  describe "relay transport metadata" do
    test "includes relay metadata in discovery document" do
      previous = Application.get_env(:elektrine, :messaging_federation)

      Application.put_env(
        :elektrine,
        :messaging_federation,
        enabled: true,
        identity_key_id: "k-relay",
        official_relay_operator: "Relay Collective",
        official_relays: [
          %{
            "name" => "Relay US-East",
            "url" => "https://relay-us-east.example.com"
          },
          "https://relay-eu.example.com"
        ],
        peers: []
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      discovery = Federation.local_discovery_document()

      assert discovery["features"]["relay_transport"] == true
      assert discovery["relay_transport"]["mode"] == "optional"
      assert discovery["relay_transport"]["community_hostable"] == true
      assert discovery["relay_transport"]["official_operator"] == "Relay Collective"

      relay_urls =
        discovery["relay_transport"]["official_relays"]
        |> Enum.map(& &1["url"])

      assert "https://relay-us-east.example.com" in relay_urls
      assert "https://relay-eu.example.com" in relay_urls
    end

    test "normalizes peer relay endpoint overrides" do
      previous = Application.get_env(:elektrine, :messaging_federation)

      Application.put_env(
        :elektrine,
        :messaging_federation,
        enabled: true,
        peers: [
          %{
            "domain" => "remote.example",
            "base_url" => "https://remote.example/",
            "shared_secret" => "relay-secret",
            "event_endpoint" => "https://relay.example.net/fwd/events",
            "sync_endpoint" => "https://relay.example.net/fwd/sync",
            "snapshot_endpoint_template" => "https://relay.example.net/fwd/snapshots/{server_id}"
          }
        ]
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      [peer] = Federation.outgoing_peers()

      assert peer.base_url == "https://remote.example"
      assert peer.event_endpoint == "https://relay.example.net/fwd/events"
      assert peer.sync_endpoint == "https://relay.example.net/fwd/sync"

      assert peer.snapshot_endpoint_template ==
               "https://relay.example.net/fwd/snapshots/{server_id}"
    end
  end
end
