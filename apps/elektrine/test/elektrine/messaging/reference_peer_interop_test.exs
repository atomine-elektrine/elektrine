defmodule Elektrine.Messaging.ReferencePeerInteropTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Federation.Config
  alias Elektrine.Messaging.FederationSessionClient
  alias Elektrine.Messaging.ReferencePeer
  alias Elektrine.Messaging.ReferencePeerSessionServer

  setup do
    previous = Application.get_env(:elektrine, :messaging_federation, [])

    Application.put_env(
      :elektrine,
      :messaging_federation,
      Keyword.merge(previous,
        enabled: true,
        identity_key_id: "local-k1",
        identity_shared_secret: "local-reference-secret",
        allow_insecure_http_transport: true,
        peers: []
      )
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :messaging_federation, previous)
    end)

    :ok
  end

  test "reference peer accepts locally signed events and replays them" do
    peer = ReferencePeer.new(domain: "reference.test", secret: "reference-secret")
    local_identity = Federation.local_discovery_document()["identity"]

    event =
      signed_local_event(
        "message.create",
        "channel:https://#{Federation.local_domain()}/_arblarg/channels/interop-local",
        1,
        message_payload(Federation.local_domain(), "interop-local", "hello from local")
      )

    assert {:ok, updated_peer, :applied} =
             ReferencePeer.receive_event(
               peer,
               event,
               ReferencePeer.key_lookup_from_identity(local_identity)
             )

    replay = ReferencePeer.export_stream_events(updated_peer, event["stream_id"])

    assert replay["last_sequence"] == 1
    assert replay["events"] |> List.first() |> Map.get("event_id") == event["event_id"]
  end

  test "federation accepts reference peer signed events discovered from reference metadata" do
    peer = ReferencePeer.new(domain: "reference.test", secret: "reference-secret")
    previous = Application.get_env(:elektrine, :messaging_federation, [])

    Application.put_env(
      :elektrine,
      :messaging_federation,
      Keyword.merge(previous,
        enabled: true,
        peers: [],
        dns_identity_fetcher: fn
          "_arblarg.reference.test", "reference.test" ->
            [authenticated_dns_identity_proof(ReferencePeer.discovery_document(peer))]

          _name, _domain ->
            []
        end,
        discovery_fetcher: fn
          "reference.test", _urls ->
            {:ok, ReferencePeer.discovery_document(peer)}

          _domain, _urls ->
            {:error, :not_found}
        end
      )
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :messaging_federation, previous)
    end)

    assert {:ok, discovered_peer} = Federation.discover_peer("reference.test")
    assert discovered_peer.domain == "reference.test"

    membership_event =
      ReferencePeer.signed_event(
        peer,
        "membership.upsert",
        "channel:https://reference.test/_arblarg/channels/interop-ref",
        1,
        membership_payload("reference.test", "interop-ref")
      )

    event =
      ReferencePeer.signed_event(
        peer,
        "message.create",
        "channel:https://reference.test/_arblarg/channels/interop-ref",
        2,
        message_payload("reference.test", "interop-ref", "hello from reference")
      )

    assert {:ok, :applied} = Federation.receive_event(membership_event, "reference.test")
    assert {:ok, :applied} = Federation.receive_event(event, "reference.test")
  end

  test "session transport multiplexes independent streams to the independent reference peer" do
    peer = ReferencePeer.new(domain: "reference.test", secret: "reference-secret")
    local_identity = Federation.local_discovery_document()["identity"]
    {local_key_id, local_private_key} = local_signing_material()

    session_server =
      start_supervised!(
        {ReferencePeerSessionServer,
         peer: peer, remote_key_lookup_fun: ReferencePeer.key_lookup_from_identity(local_identity)}
      )

    session_peer = %{
      domain: "reference.test",
      active_outbound_key_id: local_key_id,
      keys: [%{id: local_key_id, private_key: local_private_key}],
      session_websocket_endpoint:
        "ws://127.0.0.1:#{ReferencePeerSessionServer.port(session_server)}/_arblarg/session",
      transport_profiles: %{
        "session_websocket" => %{
          "encodings" => ["json"],
          "flow_control" => %{
            "max_inflight_batches" => 4,
            "max_inflight_events" => 64
          }
        }
      }
    }

    deliveries =
      for {suffix, content} <- [
            {"session-interop-a", "hello over session"},
            {"session-interop-b", "second over session"}
          ] do
        Task.async(fn ->
          FederationSessionClient.send_delivery(
            session_peer,
            "stream_batch",
            %{
              "stream_id" =>
                "channel:https://#{Federation.local_domain()}/_arblarg/channels/#{suffix}",
              "events" => [
                signed_local_event(
                  "message.create",
                  "channel:https://#{Federation.local_domain()}/_arblarg/channels/#{suffix}",
                  1,
                  message_payload(Federation.local_domain(), suffix, content)
                )
              ]
            }
          )
        end)
      end

    Enum.each(deliveries, fn delivery ->
      assert {:ok, %{"counts" => %{"applied" => 1}}} = Task.await(delivery, 5_000)
    end)

    streamed_peer = ReferencePeerSessionServer.current_peer(session_server)

    Enum.each(
      [
        {"session-interop-a", "hello over session"},
        {"session-interop-b", "second over session"}
      ],
      fn {suffix, content} ->
        replay =
          ReferencePeer.export_stream_events(
            streamed_peer,
            "channel:https://#{Federation.local_domain()}/_arblarg/channels/#{suffix}"
          )

        assert replay["last_sequence"] == 1

        assert Enum.map(replay["events"], &get_in(&1, ["payload", "message", "content"])) == [
                 content
               ]
      end
    )
  end

  defp signed_local_event(event_type, stream_id, sequence, payload) do
    {key_id, private_key} = local_signing_material()

    %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_version" => ArblargSDK.protocol_version(),
      "event_id" => "evt-#{Ecto.UUID.generate()}",
      "event_type" => event_type,
      "origin_domain" => Federation.local_domain(),
      "stream_id" => stream_id,
      "sequence" => sequence,
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "idempotency_key" => "idem-#{Ecto.UUID.generate()}",
      "payload" => payload
    }
    |> ArblargSDK.sign_event_envelope(key_id, private_key)
  end

  defp local_signing_material do
    config = Application.get_env(:elektrine, :messaging_federation, [])
    key_id = Config.local_identity_key_id(config)

    [key | _] =
      Config.local_identity_keys(
        config,
        key_id,
        Federation.local_domain(),
        true,
        false
      )

    {key.id, key.private_key}
  end

  defp message_payload(domain, suffix, content) do
    %{
      "server" => %{
        "id" => "https://#{domain}/_arblarg/servers/#{suffix}",
        "name" => "interop-#{suffix}",
        "is_public" => true
      },
      "channel" => %{
        "id" => "https://#{domain}/_arblarg/channels/#{suffix}",
        "name" => "general",
        "position" => 0
      },
      "message" => %{
        "id" => "https://#{domain}/_arblarg/messages/#{suffix}",
        "channel_id" => "https://#{domain}/_arblarg/channels/#{suffix}",
        "content" => content,
        "message_type" => "text",
        "attachments" => [],
        "sender" => %{
          "id" => "https://#{domain}/users/alice",
          "uri" => "https://#{domain}/users/alice",
          "username" => "alice",
          "display_name" => "alice",
          "domain" => domain,
          "handle" => "alice@#{domain}"
        }
      }
    }
  end

  defp membership_payload(domain, suffix) do
    %{
      "server" => %{
        "id" => "https://#{domain}/_arblarg/servers/#{suffix}",
        "name" => "interop-#{suffix}",
        "is_public" => true
      },
      "channel" => %{
        "id" => "https://#{domain}/_arblarg/channels/#{suffix}",
        "name" => "general",
        "position" => 0
      },
      "membership" => %{
        "actor" => %{
          "id" => "https://#{domain}/users/alice",
          "uri" => "https://#{domain}/users/alice",
          "username" => "alice",
          "display_name" => "alice",
          "domain" => domain,
          "handle" => "alice@#{domain}"
        },
        "state" => "active",
        "role" => "member",
        "joined_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "updated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
    }
  end

  defp discovery_fingerprint(%{
         "identity" => %{"current_key_id" => current_key_id, "keys" => keys}
       })
       when is_list(keys) do
    normalized =
      keys
      |> Enum.map(fn key ->
        %{
          "id" => key["id"],
          "public_key" => key["public_key"]
        }
      end)
      |> Enum.sort_by(&{&1["id"] || "", &1["public_key"] || ""})

    :crypto.hash(
      :sha256,
      Jason.encode!(%{"current_key_id" => current_key_id, "keys" => normalized})
    )
    |> Base.url_encode64(padding: false)
  end

  defp authenticated_dns_identity_proof(discovery_document) do
    %{
      text: "fingerprint=#{discovery_fingerprint(discovery_document)}",
      authenticated: true
    }
  end
end
