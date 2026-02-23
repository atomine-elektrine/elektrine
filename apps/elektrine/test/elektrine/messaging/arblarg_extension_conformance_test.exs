defmodule Elektrine.Messaging.ArblargExtensionConformanceTest do
  use ExUnit.Case, async: true

  alias Elektrine.Messaging.ArblargProfiles
  alias Elektrine.Messaging.ArblargSDK

  @vectors_file Path.expand(
                  "../../../../../external/arblarg/test_vectors/v1/extension_events.json",
                  __DIR__
                )

  test "CONFX-001 registry publishes discord extension pack metadata" do
    registry = ArblargProfiles.extension_registry()
    extension_urns = Enum.map(registry, & &1["urn"])

    assert "urn:arbp:ext:roles:1" in extension_urns
    assert "urn:arbp:ext:permissions:1" in extension_urns
    assert "urn:arbp:ext:threads:1" in extension_urns
    assert "urn:arbp:ext:presence:1" in extension_urns
    assert "urn:arbp:ext:moderation:1" in extension_urns

    Enum.each(registry, fn extension ->
      assert is_map(extension["conformance"])
      assert is_binary(extension["conformance"]["status"])
      assert is_binary(extension["conformance"]["suite_version"])
    end)
  end

  test "CONFX-002 extension vectors pass schema and envelope validation" do
    vectors = read_vectors!()

    Enum.each(vectors["cases"], fn vector ->
      canonical_event_type = ArblargSDK.canonical_event_type(vector["event_type_alias"])

      assert canonical_event_type == vector["expected_event_type"]
      assert canonical_event_type in ArblargSDK.supported_event_types()
      assert is_map(ArblargSDK.schema("1.0", vector["expected_schema"]))
      assert :ok = ArblargSDK.validate_event_payload(canonical_event_type, vector["payload"])

      assert :ok =
               ArblargSDK.validate_event_envelope(
                 build_envelope(canonical_event_type, vector["payload"])
               )

      expected_invalid_error = String.to_atom(vector["expected_invalid_error"])

      assert {:error, ^expected_invalid_error} =
               ArblargSDK.validate_event_payload(canonical_event_type, vector["invalid_payload"])

      assert {:error, ^expected_invalid_error} =
               ArblargSDK.validate_event_envelope(
                 build_envelope(canonical_event_type, vector["invalid_payload"])
               )
    end)
  end

  defp build_envelope(event_type, payload) do
    %{
      "protocol" => "arblarg",
      "protocol_id" => "arbp",
      "protocol_version" => "1.0",
      "event_type" => event_type,
      "event_id" => "evt-#{Ecto.UUID.generate()}",
      "origin_domain" => "example.net",
      "stream_id" => "channel:https://example.net/federation/messaging/channels/1",
      "sequence" => 1,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "idempotency_key" => "idem-#{Ecto.UUID.generate()}",
      "payload" => payload
    }
  end

  defp read_vectors! do
    @vectors_file
    |> File.read!()
    |> Jason.decode!()
  end
end
