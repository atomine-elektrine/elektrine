defmodule Elektrine.Messaging.FederationProtocolTest do
  use ExUnit.Case, async: true

  alias Elektrine.Messaging.Federation.Protocol

  test "advertises expanded protocol feature contract" do
    document =
      Protocol.local_discovery_document("1.0", %{
        local_domain: "local.test",
        base_url: "https://local.test",
        identity: %{}
      })

    features = document["features"]

    assert features["deterministic_governance_projection"] == true
    assert features["client_sync_cursors"] == true
    assert features["gateway_resume"] == true
    assert features["attachment_authorization_metadata"] == true
    assert features["rich_room_metadata"] == true
    assert features["federation_abuse_controls"] == true
  end
end
