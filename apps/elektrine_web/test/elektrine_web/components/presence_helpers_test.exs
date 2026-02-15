defmodule ElektrineWeb.Components.Presence.HelpersTest do
  use ExUnit.Case, async: true

  alias ElektrineWeb.Components.Presence.Helpers, as: PresenceHelpers

  describe "format_last_seen/2" do
    test "returns 'Last seen just now' for < 1 minute" do
      now = System.system_time(:second)
      last_seen = now - 30

      assert PresenceHelpers.format_last_seen("offline", last_seen) == "Last seen just now"
    end

    test "returns minutes for < 1 hour" do
      now = System.system_time(:second)
      # 5 minutes ago
      last_seen = now - 5 * 60

      assert PresenceHelpers.format_last_seen("offline", last_seen) == "Last seen 5m ago"
    end

    test "returns hours for < 1 day" do
      now = System.system_time(:second)
      # 3 hours ago
      last_seen = now - 3 * 3600

      assert PresenceHelpers.format_last_seen("offline", last_seen) == "Last seen 3h ago"
    end

    test "returns days for < 1 week" do
      now = System.system_time(:second)
      # 2 days ago
      last_seen = now - 2 * 86400

      assert PresenceHelpers.format_last_seen("offline", last_seen) == "Last seen 2d ago"
    end

    test "returns 'a while ago' for > 1 week" do
      now = System.system_time(:second)
      # 10 days ago
      last_seen = now - 10 * 86400

      assert PresenceHelpers.format_last_seen("offline", last_seen) == "Last seen a while ago"
    end

    test "returns nil for non-offline statuses" do
      now = System.system_time(:second)

      assert is_nil(PresenceHelpers.format_last_seen("online", now))
      assert is_nil(PresenceHelpers.format_last_seen("away", now))
      assert is_nil(PresenceHelpers.format_last_seen("dnd", now))
    end

    test "returns nil for invalid timestamps" do
      assert is_nil(PresenceHelpers.format_last_seen("offline", nil))
      assert is_nil(PresenceHelpers.format_last_seen("offline", "invalid"))
    end
  end

  describe "status_text/2" do
    test "returns correct text for online" do
      assert PresenceHelpers.status_text("online", nil) == "Online"
    end

    test "returns correct text for away" do
      assert PresenceHelpers.status_text("away", nil) == "Away"
    end

    test "returns correct text for dnd" do
      assert PresenceHelpers.status_text("dnd", nil) == "Do Not Disturb"
    end

    test "returns 'Offline' for offline without last_seen" do
      assert PresenceHelpers.status_text("offline", nil) == "Offline"
    end

    test "returns last seen text for offline with timestamp" do
      now = System.system_time(:second)
      # 15 minutes ago
      last_seen = now - 15 * 60

      result = PresenceHelpers.status_text("offline", last_seen)
      assert result == "Last seen 15m ago"
    end

    test "defaults to 'Online' for unknown status" do
      assert PresenceHelpers.status_text("unknown", nil) == "Online"
      assert PresenceHelpers.status_text(nil, nil) == "Online"
    end
  end
end
