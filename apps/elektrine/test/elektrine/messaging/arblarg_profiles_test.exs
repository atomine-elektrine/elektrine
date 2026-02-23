defmodule Elektrine.Messaging.ArblargProfilesTest do
  use ExUnit.Case, async: true

  alias Elektrine.Messaging.ArblargProfiles

  test "exposes mandatory core profile metadata" do
    assert ArblargProfiles.core_profile_id() == "arbp-core/1.0"

    assert ArblargProfiles.core_event_types() == [
             "message.create",
             "message.update",
             "message.delete",
             "reaction.add",
             "reaction.remove",
             "read.receipt"
           ]
  end

  test "gates profile claims by conformance status" do
    assert ArblargProfiles.passing_profile_claims(core_passed?: true, discord_passed?: false) ==
             ["arbp-core/1.0"]

    assert ArblargProfiles.passing_profile_claims(core_passed?: false, discord_passed?: false) ==
             []
  end

  test "claims discord profile when required extensions are marked passing" do
    extension_statuses = %{
      "urn:arbp:ext:roles:1" => true,
      "urn:arbp:ext:permissions:1" => true,
      "urn:arbp:ext:threads:1" => true,
      "urn:arbp:ext:presence:1" => true,
      "urn:arbp:ext:moderation:1" => true
    }

    claims =
      ArblargProfiles.passing_profile_claims(
        core_passed?: true,
        extension_statuses: extension_statuses
      )

    assert "arbp-core/1.0" in claims
    assert "arbp-discord/1.0" in claims
  end

  test "registers strict extension metadata" do
    registry = ArblargProfiles.extension_registry()
    extension_urns = registry |> Enum.map(& &1["urn"])

    assert "urn:arbp:ext:bootstrap:1" in extension_urns
    assert "urn:arbp:ext:roles:1" in extension_urns
    assert "urn:arbp:ext:permissions:1" in extension_urns
    assert "urn:arbp:ext:threads:1" in extension_urns
    assert "urn:arbp:ext:presence:1" in extension_urns
    assert "urn:arbp:ext:voice:1" in extension_urns
    assert "urn:arbp:ext:moderation:1" in extension_urns

    Enum.each(registry, fn extension ->
      assert is_map(extension["conformance"])
      assert extension["fallback"] == "ignore_event"
    end)
  end
end
