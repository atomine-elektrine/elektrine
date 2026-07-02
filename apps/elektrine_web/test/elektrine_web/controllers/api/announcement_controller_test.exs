defmodule ElektrineWeb.API.AnnouncementControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Admin
  alias ElektrineWeb.API.AnnouncementController

  import Elektrine.AccountsFixtures

  describe "index/2" do
    test "lists active announcements not dismissed by the current user", %{conn: conn} do
      user = user_fixture()
      admin = user_fixture()

      {:ok, visible} =
        Admin.create_announcement(%{
          title: "Visible maintenance",
          content: "Scheduled maintenance tonight",
          type: "maintenance",
          created_by_id: admin.id,
          active: true
        })

      {:ok, dismissed} =
        Admin.create_announcement(%{
          title: "Already handled",
          content: "This was dismissed",
          type: "info",
          created_by_id: admin.id,
          active: true
        })

      {:ok, _inactive} =
        Admin.create_announcement(%{
          title: "Hidden",
          content: "Inactive",
          type: "warning",
          created_by_id: admin.id,
          active: false
        })

      assert {:ok, _dismissal} = Admin.dismiss_announcement_for_user(user.id, dismissed.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> AnnouncementController.index(%{})

      assert [announcement] = json_response(conn, 200)
      assert announcement["id"] == to_string(visible.id)
      assert announcement["title"] == "Visible maintenance"
      assert announcement["type"] == "maintenance"
      assert announcement["content"] == "Scheduled maintenance tonight"
    end
  end

  describe "dismiss/2" do
    test "dismisses an active announcement", %{conn: conn} do
      user = user_fixture()
      admin = user_fixture()

      {:ok, announcement} =
        Admin.create_announcement(%{
          title: "Dismiss me",
          content: "Dismissible",
          type: "info",
          created_by_id: admin.id,
          active: true
        })

      conn =
        conn
        |> assign(:current_user, user)
        |> AnnouncementController.dismiss(%{"id" => to_string(announcement.id)})

      assert %{"id" => id, "dismissed" => true} = json_response(conn, 200)
      assert id == to_string(announcement.id)
      assert Admin.announcement_dismissed_by_user?(user.id, announcement.id)
    end

    test "is idempotent for already dismissed announcements", %{conn: conn} do
      user = user_fixture()
      admin = user_fixture()

      {:ok, announcement} =
        Admin.create_announcement(%{
          title: "Dismiss once",
          content: "Dismissible",
          type: "info",
          created_by_id: admin.id,
          active: true
        })

      assert {:ok, _dismissal} = Admin.dismiss_announcement_for_user(user.id, announcement.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> AnnouncementController.dismiss(%{"id" => to_string(announcement.id)})

      assert %{"id" => id, "dismissed" => true} = json_response(conn, 200)
      assert id == to_string(announcement.id)
    end

    test "returns not found for malformed ids", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AnnouncementController.dismiss(%{"id" => "bad"})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end
end
