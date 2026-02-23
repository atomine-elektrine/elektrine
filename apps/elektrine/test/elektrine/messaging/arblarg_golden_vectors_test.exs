defmodule Elektrine.Messaging.ArblargGoldenVectorsTest do
  use ExUnit.Case, async: true

  alias Elektrine.Messaging.ArblargSDK

  @vectors_root Path.expand("../../../../../external/arblarg/test_vectors/v1", __DIR__)

  test "event signature golden vector" do
    vector = read_vector!("event_message_create.json")
    envelope = vector["unsigned_envelope"]
    expected = vector["expected"]

    canonical_payload = ArblargSDK.canonical_event_payload_for_signing(envelope)
    signature = ArblargSDK.sign_payload(canonical_payload, vector["signing_secret"])

    assert canonical_payload == expected["canonical_event_payload"]
    assert signature == expected["signature"]

    assert ArblargSDK.verify_payload_signature(
             canonical_payload,
             vector["public_key"],
             signature
           )
  end

  test "request signature golden vector" do
    vector = read_vector!("request_signature.json")
    expected = vector["expected"]

    body_digest = ArblargSDK.body_digest(vector["body"])

    canonical_payload =
      ArblargSDK.canonical_request_signature_payload(
        vector["domain"],
        vector["method"],
        vector["path"],
        vector["query"],
        vector["timestamp"],
        body_digest,
        vector["request_id"]
      )

    signature = ArblargSDK.sign_payload(canonical_payload, vector["signing_secret"])

    assert body_digest == expected["body_digest"]
    assert canonical_payload == expected["canonical_request_payload"]
    assert signature == expected["signature"]
  end

  test "error case golden vectors" do
    vector = read_vector!("error_cases.json")

    Enum.each(vector["cases"], fn case_vector ->
      expected_error = String.to_atom(case_vector["expected_error"])

      assert {:error, ^expected_error} =
               ArblargSDK.validate_event_envelope(case_vector["envelope"])
    end)
  end

  test "extension event golden vectors" do
    vector = read_vector!("extension_events.json")

    Enum.each(vector["cases"], fn case_vector ->
      canonical_event_type = ArblargSDK.canonical_event_type(case_vector["event_type_alias"])
      expected_invalid_error = String.to_atom(case_vector["expected_invalid_error"])

      assert canonical_event_type == case_vector["expected_event_type"]
      assert :ok = ArblargSDK.validate_event_payload(canonical_event_type, case_vector["payload"])
      assert is_map(ArblargSDK.schema("1.0", case_vector["expected_schema"]))

      assert {:error, ^expected_invalid_error} =
               ArblargSDK.validate_event_payload(
                 canonical_event_type,
                 case_vector["invalid_payload"]
               )
    end)
  end

  defp read_vector!(file_name) do
    @vectors_root
    |> Path.join(file_name)
    |> File.read!()
    |> Jason.decode!()
  end
end
