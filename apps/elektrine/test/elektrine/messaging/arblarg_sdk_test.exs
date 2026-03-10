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
    envelope =
      %{
        "protocol" => ArblargSDK.protocol_name(),
        "protocol_id" => "arblarg",
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
            "content" => "hello",
            "sender" => canonical_actor("alice", "remote.test")
          }
        }
      }
      |> ArblargSDK.sign_event_envelope("k1", "shared-test-secret")

    assert :ok = ArblargSDK.validate_event_envelope(envelope)
  end

  test "rejects unsigned durable envelopes" do
    envelope = %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => "arblarg",
      "protocol_version" => "1.0",
      "event_type" => "message.create",
      "event_id" => "evt-unsigned",
      "origin_domain" => "remote.test",
      "stream_id" => "channel:https://remote.test/federation/messaging/channels/1",
      "sequence" => 1,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "idempotency_key" => "idem-unsigned",
      "payload" => %{
        "server" => %{"id" => "https://remote.test/federation/messaging/servers/1"},
        "channel" => %{"id" => "https://remote.test/federation/messaging/channels/1"},
        "message" => %{
          "id" => "https://remote.test/federation/messaging/messages/1",
          "channel_id" => "https://remote.test/federation/messaging/channels/1",
          "content" => "hello",
          "sender" => canonical_actor("alice", "remote.test")
        }
      }
    }

    assert {:error, :invalid_signature} = ArblargSDK.validate_event_envelope(envelope)
  end

  test "rejects user-authored events whose actor omits uri" do
    envelope =
      %{
        "protocol" => ArblargSDK.protocol_name(),
        "protocol_id" => "arblarg",
        "protocol_version" => "1.0",
        "event_type" => "message.create",
        "event_id" => "evt-missing-uri",
        "origin_domain" => "remote.test",
        "stream_id" => "channel:https://remote.test/federation/messaging/channels/1",
        "sequence" => 1,
        "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "idempotency_key" => "idem-missing-uri",
        "payload" => %{
          "server" => %{"id" => "https://remote.test/federation/messaging/servers/1"},
          "channel" => %{"id" => "https://remote.test/federation/messaging/channels/1"},
          "message" => %{
            "id" => "https://remote.test/federation/messaging/messages/1",
            "channel_id" => "https://remote.test/federation/messaging/channels/1",
            "content" => "hello",
            "sender" =>
              canonical_actor("alice", "remote.test")
              |> Map.delete("uri")
              |> Map.delete("id")
          }
        }
      }
      |> ArblargSDK.sign_event_envelope("k1", "shared-test-secret")

    assert {:error, :invalid_event_payload} = ArblargSDK.validate_event_envelope(envelope)
  end

  test "rejects user-authored events whose actor uri is not absolute http or https" do
    envelope =
      %{
        "protocol" => ArblargSDK.protocol_name(),
        "protocol_id" => "arblarg",
        "protocol_version" => "1.0",
        "event_type" => "message.create",
        "event_id" => "evt-invalid-uri",
        "origin_domain" => "remote.test",
        "stream_id" => "channel:https://remote.test/federation/messaging/channels/1",
        "sequence" => 1,
        "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "idempotency_key" => "idem-invalid-uri",
        "payload" => %{
          "server" => %{"id" => "https://remote.test/federation/messaging/servers/1"},
          "channel" => %{"id" => "https://remote.test/federation/messaging/channels/1"},
          "message" => %{
            "id" => "https://remote.test/federation/messaging/messages/1",
            "channel_id" => "https://remote.test/federation/messaging/channels/1",
            "content" => "hello",
            "sender" =>
              canonical_actor("alice", "remote.test")
              |> Map.put("uri", "acct:alice@remote.test")
          }
        }
      }
      |> ArblargSDK.sign_event_envelope("k1", "shared-test-secret")

    assert {:error, :invalid_event_payload} = ArblargSDK.validate_event_envelope(envelope)
  end

  test "rejects unsupported protocol id" do
    envelope = %{
      "protocol" => ArblargSDK.protocol_name(),
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

  test "rejects non-spec top-level server_id and channel_id context" do
    envelope =
      %{
        "protocol" => ArblargSDK.protocol_name(),
        "protocol_id" => "arblarg",
        "protocol_version" => "1.0",
        "event_type" => "message.create",
        "event_id" => "evt-top-level-context",
        "origin_domain" => "remote.test",
        "stream_id" => "channel:https://remote.test/federation/messaging/channels/1",
        "sequence" => 1,
        "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "idempotency_key" => "idem-top-level-context",
        "payload" => %{
          "server_id" => "https://remote.test/federation/messaging/servers/1",
          "channel_id" => "https://remote.test/federation/messaging/channels/1",
          "message" => %{
            "id" => "https://remote.test/federation/messaging/messages/1",
            "content" => "hello",
            "sender" => canonical_actor("alice", "remote.test")
          }
        }
      }
      |> ArblargSDK.sign_event_envelope("k1", "shared-test-secret")

    assert {:error, :invalid_event_payload} = ArblargSDK.validate_event_envelope(envelope)
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

  test "normalizes extension event aliases" do
    assert ArblargSDK.canonical_event_type("server.upsert") ==
             "urn:arblarg:ext:bootstrap:1#server.upsert"

    assert ArblargSDK.canonical_event_type("role.upsert") ==
             "urn:arblarg:ext:roles:1#role.upsert"

    assert ArblargSDK.canonical_event_type("thread.archive") ==
             "urn:arblarg:ext:threads:1#thread.archive"

    assert ArblargSDK.canonical_event_type("moderation.action.recorded") ==
             "urn:arblarg:ext:moderation:1#action.recorded"
  end

  test "validates community extension event envelopes" do
    envelope =
      %{
        "protocol" => ArblargSDK.protocol_name(),
        "protocol_id" => "arblarg",
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
      |> ArblargSDK.sign_event_envelope("k1", "shared-test-secret")

    assert :ok = ArblargSDK.validate_event_envelope(envelope)
    assert "urn:arblarg:ext:moderation:1#action.recorded" in ArblargSDK.supported_event_types()
  end

  test "published schema artifacts mirror the live SDK" do
    version = ArblargSDK.protocol_version()
    schema_dir = Path.expand("../../../../../external/arblarg/schemas/v1", __DIR__)

    published =
      schema_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort()

    expected =
      ArblargSDK.schema_names(version)
      |> Enum.map(&"#{&1}.json")
      |> Enum.sort()

    assert published == expected

    Enum.each(ArblargSDK.schema_names(version), fn schema_name ->
      published_schema =
        schema_dir
        |> Path.join("#{schema_name}.json")
        |> File.read!()
        |> Jason.decode!()

      assert published_schema == ArblargSDK.schema(version, schema_name)
    end)
  end

  defp canonical_actor(username, domain) do
    %{
      "id" => "https://#{domain}/users/#{username}",
      "uri" => "https://#{domain}/users/#{username}",
      "username" => username,
      "display_name" => username,
      "domain" => domain,
      "handle" => "#{username}@#{domain}"
    }
  end
end
