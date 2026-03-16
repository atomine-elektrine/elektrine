defmodule Elektrine.Messaging.ArblargProfilesTest do
  use ExUnit.Case, async: true

  alias Elektrine.Messaging.ArblargProfiles

  test "exposes mandatory core profile metadata" do
    assert ArblargProfiles.core_profile_id() == "arblarg-core/1.0"

    assert ArblargProfiles.core_event_types() == [
             "message.create",
             "message.update",
             "message.delete",
             "reaction.add",
             "reaction.remove",
             "read.cursor",
             "membership.upsert",
             "invite.upsert",
             "ban.upsert"
           ]
  end

  test "gates profile claims by conformance status" do
    assert ArblargProfiles.passing_profile_claims(core_passed?: true, community_passed?: false) ==
             ["arblarg-core/1.0"]

    assert ArblargProfiles.passing_profile_claims(core_passed?: false, community_passed?: false) ==
             []
  end

  test "claims community profile when required extensions are marked passing" do
    extension_statuses = %{
      "urn:arblarg:ext:roles:1" => true,
      "urn:arblarg:ext:permissions:1" => true,
      "urn:arblarg:ext:threads:1" => true,
      "urn:arblarg:ext:presence:1" => true,
      "urn:arblarg:ext:moderation:1" => true
    }

    claims =
      ArblargProfiles.passing_profile_claims(
        core_passed?: true,
        extension_statuses: extension_statuses
      )

    assert "arblarg-core/1.0" in claims
    assert "arblarg-community/1.0" in claims
  end

  test "registers strict extension metadata" do
    registry = ArblargProfiles.extension_registry()
    extension_urns = registry |> Enum.map(& &1["urn"])

    assert "urn:arblarg:ext:bootstrap:1" in extension_urns
    assert "urn:arblarg:ext:roles:1" in extension_urns
    assert "urn:arblarg:ext:permissions:1" in extension_urns
    assert "urn:arblarg:ext:threads:1" in extension_urns
    assert "urn:arblarg:ext:presence:1" in extension_urns
    assert "urn:arblarg:ext:voice:1" in extension_urns
    assert "urn:arblarg:ext:moderation:1" in extension_urns

    Enum.each(registry, fn extension ->
      assert is_map(extension["conformance"])
      assert extension["fallback"] == "reject_unsupported_event_type"
    end)
  end
end
