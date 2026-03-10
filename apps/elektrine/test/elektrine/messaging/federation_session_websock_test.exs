defmodule Elektrine.Messaging.FederationSessionWebSockTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.FederationSessionWebSock

  setup do
    previous = Application.get_env(:elektrine, :messaging_federation)

    Application.put_env(
      :elektrine,
      :messaging_federation,
      enabled: true,
      identity_key_id: "local-k1",
      conformance_core_passed: true,
      peers: [
        %{
          "domain" => "remote.test",
          "base_url" => "https://remote.test",
          "shared_secret" => "test-shared-secret",
          "active_outbound_key_id" => "k1",
          "keys" => [
            %{"id" => "k1", "secret" => "test-shared-secret", "active_outbound" => true}
          ],
          "allow_incoming" => true,
          "allow_outgoing" => true
        }
      ]
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :messaging_federation, previous)
    end)

    :ok
  end

  test "accepts delivery frames and returns batch-shaped ack payloads" do
    {:push, {:text, _hello}, state} =
      FederationSessionWebSock.init(%{remote_domain: "remote.test"})

    frame = %{
      "op" => "stream_batch",
      "delivery_id" => "delivery-1",
      "payload" => %{
        "version" => 1,
        "delivery_id" => "delivery-1",
        "stream_id" => "server:https://remote.test/federation/messaging/servers/77",
        "events" => [signed_server_upsert_event("evt-session-1", 1, "session-room")]
      }
    }

    {:push, {:text, payload}, _state} =
      FederationSessionWebSock.handle_in({Jason.encode!(frame), [opcode: :text]}, state)

    response = Jason.decode!(payload)

    assert response["op"] == "ack"
    assert response["delivery_id"] == "delivery-1"
    assert response["status"] == "ok"
    assert response["payload"]["batch_id"] == "delivery-1"
    assert response["payload"]["event_count"] == 1
    assert response["payload"]["counts"]["applied"] == 1
  end

  test "rejects delivery frames whose payload omits the required delivery_id" do
    {:push, {:text, _hello}, state} =
      FederationSessionWebSock.init(%{remote_domain: "remote.test"})

    frame = %{
      "op" => "stream_batch",
      "delivery_id" => "delivery-2",
      "payload" => %{
        "version" => 1,
        "stream_id" => "server:https://remote.test/federation/messaging/servers/78",
        "events" => [signed_server_upsert_event("evt-session-2", 1, "invalid-session-room")]
      }
    }

    {:push, {:text, payload}, _state} =
      FederationSessionWebSock.handle_in({Jason.encode!(frame), [opcode: :text]}, state)

    response = Jason.decode!(payload)

    assert response["op"] == "ack"
    assert response["delivery_id"] == "delivery-2"
    assert response["status"] == "error"
    assert response["code"] == "invalid_payload"
  end

  defp signed_server_upsert_event(event_id, sequence, server_name) do
    server_id = "https://remote.test/federation/messaging/servers/77"
    stream_id = "server:#{server_id}"

    %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_version" => ArblargSDK.protocol_version(),
      "event_id" => event_id,
      "event_type" => "server.upsert",
      "origin_domain" => "remote.test",
      "stream_id" => stream_id,
      "sequence" => sequence,
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "idempotency_key" => "idem-#{event_id}",
      "payload" => %{
        "server" => %{
          "id" => server_id,
          "name" => server_name,
          "is_public" => true
        },
        "channels" => []
      }
    }
    |> ArblargSDK.sign_event_envelope("k1", "test-shared-secret")
  end
end
