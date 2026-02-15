defmodule ElektrineWeb.PresenceTest do
  use Elektrine.DataCase

  alias ElektrineWeb.Presence
  alias Elektrine.Accounts

  describe "presence tracking" do
    test "can track user presence" do
      user_id = "123"

      Presence.track(self(), "users", user_id, %{
        user_id: 123,
        username: "testuser",
        status: "online",
        online_at: System.system_time(:second)
      })

      # Allow time for presence to sync
      Process.sleep(100)

      presences = Presence.list("users")
      assert Map.has_key?(presences, user_id)
    end

    test "presence diff broadcasts when users join" do
      # Subscribe to presence updates
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "users")

      # Track a user
      user_id = "456"

      Presence.track(self(), "users", user_id, %{
        user_id: 456,
        username: "newuser",
        status: "online",
        online_at: System.system_time(:second)
      })

      # Should receive presence_diff broadcast
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "presence_diff",
                       payload: %{joins: joins}
                     },
                     1000

      assert Map.has_key?(joins, user_id)
    end

    test "presence diff broadcasts when users leave" do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "users")

      user_id = "789"

      pid =
        spawn(fn ->
          Presence.track(self(), "users", user_id, %{
            user_id: 789,
            username: "leavinguser",
            status: "online",
            online_at: System.system_time(:second)
          })

          receive do
            :stop -> :ok
          end
        end)

      # Wait for join
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{joins: _}}, 1000

      # Kill the process to trigger leave
      Process.exit(pid, :kill)

      # Should receive leave broadcast
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "presence_diff",
                       payload: %{leaves: leaves}
                     },
                     1000

      assert Map.has_key?(leaves, user_id)
    end

    test "can update user presence metadata" do
      user_id = "999"

      Presence.track(self(), "users", user_id, %{
        user_id: 999,
        username: "updateuser",
        status: "online",
        online_at: System.system_time(:second)
      })

      Process.sleep(100)

      # Update status
      Presence.update(self(), "users", user_id, fn meta ->
        Map.put(meta, :status, "away")
      end)

      Process.sleep(100)

      presences = Presence.list("users")
      user_presence = Map.get(presences, user_id)
      assert user_presence
      [meta | _] = user_presence.metas
      assert meta.status == "away"
    end
  end

  describe "presence metadata" do
    test "includes required fields" do
      user_id = "111"

      Presence.track(self(), "users", user_id, %{
        user_id: 111,
        username: "metauser",
        status: "online",
        status_message: "Working",
        online_at: System.system_time(:second),
        last_seen_at: System.system_time(:second)
      })

      Process.sleep(100)

      presences = Presence.list("users")
      user_presence = Map.get(presences, user_id)
      [meta | _] = user_presence.metas

      assert meta.user_id == 111
      assert meta.username == "metauser"
      assert meta.status == "online"
      assert meta.status_message == "Working"
      assert meta.online_at
      assert meta.last_seen_at
    end
  end

  describe "status color mapping" do
    import Phoenix.LiveViewTest

    test "online returns green" do
      html =
        render_component(&ElektrineWeb.Components.User.Avatar.user_avatar/1,
          user: %{id: 1, username: "test"},
          size: "md",
          user_statuses: %{"1" => %{status: "online"}},
          online: false
        )

      assert html =~ "bg-success"
    end

    test "away returns yellow" do
      html =
        render_component(&ElektrineWeb.Components.User.Avatar.user_avatar/1,
          user: %{id: 1, username: "test"},
          size: "md",
          user_statuses: %{"1" => %{status: "away"}},
          online: false
        )

      assert html =~ "bg-warning"
    end

    test "dnd returns red" do
      html =
        render_component(&ElektrineWeb.Components.User.Avatar.user_avatar/1,
          user: %{id: 1, username: "test"},
          size: "md",
          user_statuses: %{"1" => %{status: "dnd"}},
          online: false
        )

      assert html =~ "bg-error"
    end

    test "offline returns gray" do
      html =
        render_component(&ElektrineWeb.Components.User.Avatar.user_avatar/1,
          user: %{id: 1, username: "test"},
          size: "md",
          user_statuses: %{"1" => %{status: "offline"}},
          online: false
        )

      assert html =~ "bg-gray-400"
    end
  end
end
