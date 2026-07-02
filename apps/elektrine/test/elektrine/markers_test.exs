defmodule Elektrine.MarkersTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.Markers
  alias Elektrine.Notifications.Notification
  alias Elektrine.Repo

  describe "timeline markers" do
    test "creates and reads requested markers" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, markers} =
               Markers.upsert_markers(user.id, %{
                 "home" => %{"last_read_id" => "100"},
                 "notifications" => %{"last_read_id" => "50"}
               })

      assert markers["home"].last_read_id == "100"
      assert markers["notifications"].last_read_id == "50"

      listed = Markers.list_markers(user.id, ["home"])

      assert Map.keys(listed) == ["home"]
      assert listed["home"].last_read_id == "100"
    end

    test "notification markers include unread count" do
      user = AccountsFixtures.user_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      insert_notification!(user.id, %{title: "Unread one"})
      insert_notification!(user.id, %{title: "Unread two"})
      insert_notification!(user.id, %{title: "Read", read_at: now})
      insert_notification!(user.id, %{title: "Dismissed", dismissed_at: now})

      assert {:ok, %{"notifications" => marker}} =
               Markers.upsert_markers(user.id, %{
                 "notifications" => %{"last_read_id" => "10"}
               })

      assert marker.unread_count == 2

      listed = Markers.list_markers(user.id, ["notifications"])
      assert listed["notifications"].unread_count == 2
      assert Markers.format_marker(listed["notifications"]).unread_count == 2
    end

    test "updates existing markers and increments version" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, %{"home" => first}} =
               Markers.upsert_markers(user.id, %{"home" => %{"last_read_id" => "100"}})

      assert first.version == 0

      assert {:ok, %{"home" => second}} =
               Markers.upsert_markers(user.id, %{"home" => %{"last_read_id" => "200"}})

      assert second.last_read_id == "200"
      assert second.version == 1
    end

    test "rejects invalid marker data" do
      user = AccountsFixtures.user_fixture()

      assert {:error, changeset} =
               Markers.upsert_markers(user.id, %{
                 "../home" => %{"last_read_id" => "100"}
               })

      assert %{timeline: [_]} = errors_on(changeset)
    end

    test "ignores payload entries without last_read_id" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, markers} =
               Markers.upsert_markers(user.id, %{
                 "home" => %{"id" => "100"},
                 "notifications" => %{"last_read_id" => "10"}
               })

      assert Map.keys(markers) == ["notifications"]
    end
  end

  defp insert_notification!(user_id, attrs) do
    attrs =
      Map.merge(
        %{
          type: "system",
          title: "Notification",
          body: "Body",
          user_id: user_id
        },
        attrs
      )

    %Notification{}
    |> Notification.changeset(attrs)
    |> Repo.insert!()
  end
end
