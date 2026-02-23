defmodule Elektrine.Messaging.ArblargSDKTest do
  use ExUnit.Case, async: true

  alias Elektrine.Messaging.ArblargSDK

  test "signs and verifies detached payload signatures" do
    payload = "hello-arblarg"
    secret = "shared-test-secret"

    signature = ArblargSDK.sign_payload(payload, secret)

    assert is_binary(signature)
    assert ArblargSDK.verify_payload_signature(payload, secret, signature)
    refute ArblargSDK.verify_payload_signature("tampered", secret, signature)
  end

  test "validates v1 event envelope and payload" do
    envelope = %{
      "protocol" => "arblarg",
      "protocol_id" => "arbp",
      "protocol_version" => "1.0",
      "event_type" => "message.create",
      "event_id" => "evt-1",
      "origin_domain" => "remote.test",
      "stream_id" => "channel:https://remote.test/federation/messaging/channels/1",
      "sequence" => 1,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "idempotency_key" => "idem-1",
      "payload" => %{
        "server" => %{"id" => "https://remote.test/federation/messaging/servers/1"},
        "channel" => %{"id" => "https://remote.test/federation/messaging/channels/1"},
        "message" => %{
          "id" => "https://remote.test/federation/messaging/messages/1",
          "channel_id" => "https://remote.test/federation/messaging/channels/1",
          "content" => "hello"
        }
      }
    }

    assert :ok = ArblargSDK.validate_event_envelope(envelope)
  end

  test "rejects unsupported protocol id" do
    envelope = %{
      "protocol" => "arblarg",
      "protocol_id" => "wrong",
      "protocol_version" => "1.0",
      "event_type" => "server.upsert",
      "event_id" => "evt-2",
      "origin_domain" => "remote.test",
      "stream_id" => "server:https://remote.test/federation/messaging/servers/1",
      "sequence" => 1,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "idempotency_key" => "idem-2",
      "payload" => %{
        "server" => %{"id" => "https://remote.test/federation/messaging/servers/1"},
        "channels" => []
      }
    }

    assert {:error, :unsupported_protocol} = ArblargSDK.validate_event_envelope(envelope)
  end

  test "retries failing operations" do
    attempt_counter = :atomics.new(1, [])

    result =
      ArblargSDK.with_retries(
        fn ->
          count = :atomics.add_get(attempt_counter, 1, 1)

          if count < 3 do
            {:error, :retry}
          else
            {:ok, :done}
          end
        end,
        attempts: 3,
        base_backoff_ms: 1,
        jitter_ms: 0
      )

    assert result == {:ok, :done}
  end

  test "exposes protocol schemas" do
    assert is_map(ArblargSDK.schema("1.0", "envelope"))
    assert is_map(ArblargSDK.schema("1.0", "message.create"))
    assert ArblargSDK.schema("1.0", "unknown") == nil
  end

  test "normalizes legacy extension event aliases" do
    assert ArblargSDK.canonical_event_type("server.upsert") ==
             "urn:arbp:ext:bootstrap:1#server.upsert"

    assert ArblargSDK.canonical_event_type("role.upsert") ==
             "urn:arbp:ext:roles:1#role.upsert"

    assert ArblargSDK.canonical_event_type("thread.archive") ==
             "urn:arbp:ext:threads:1#thread.archive"

    assert ArblargSDK.canonical_event_type("moderation.action.recorded") ==
             "urn:arbp:ext:moderation:1#action.recorded"
  end

  test "validates discord extension event envelopes" do
    envelope = %{
      "protocol" => "arblarg",
      "protocol_id" => "arbp",
      "protocol_version" => "1.0",
      "event_type" => "role.upsert",
      "event_id" => "evt-ext-1",
      "origin_domain" => "remote.test",
      "stream_id" => "channel:https://remote.test/federation/messaging/channels/1",
      "sequence" => 1,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "idempotency_key" => "idem-ext-1",
      "payload" => %{
        "server" => %{"id" => "https://remote.test/federation/messaging/servers/1"},
        "channel" => %{"id" => "https://remote.test/federation/messaging/channels/1"},
        "role" => %{
          "id" => "role-admin",
          "name" => "Admin",
          "permissions" => ["manage_messages"],
          "position" => 1
        }
      }
    }

    assert :ok = ArblargSDK.validate_event_envelope(envelope)
    assert "urn:arbp:ext:moderation:1#action.recorded" in ArblargSDK.supported_event_types()
  end
end
