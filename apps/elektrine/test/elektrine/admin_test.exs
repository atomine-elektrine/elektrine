defmodule Elektrine.AdminTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  alias Elektrine.Admin

  describe "announcements" do
    setup do
      {:ok, admin} =
        Accounts.create_user(%{
          username: "adminuser",
          password: "password123",
          password_confirmation: "password123"
        })

      %{admin: admin}
    end

    test "list_announcements/0 returns all announcements", %{admin: admin} do
      {:ok, _announcement} =
        Admin.create_announcement(%{
          title: "Test Announcement",
          content: "This is a test announcement",
          type: "info",
          created_by_id: admin.id,
          active: true
        })

      announcements = Admin.list_announcements()
      assert length(announcements) == 1
      assert hd(announcements).title == "Test Announcement"
    end

    test "list_active_announcements/0 returns only active announcements", %{admin: admin} do
      {:ok, _active} =
        Admin.create_announcement(%{
          title: "Active Announcement",
          content: "This is active",
          type: "info",
          created_by_id: admin.id,
          active: true
        })

      {:ok, _inactive} =
        Admin.create_announcement(%{
          title: "Inactive Announcement",
          content: "This is inactive",
          type: "warning",
          created_by_id: admin.id,
          active: false
        })

      active_announcements = Admin.list_active_announcements()
      assert length(active_announcements) == 1
      assert hd(active_announcements).title == "Active Announcement"
    end

    test "get_announcement!/1 returns the announcement with given id", %{admin: admin} do
      {:ok, announcement} =
        Admin.create_announcement(%{
          title: "Get Test",
          content: "Test content",
          type: "feature",
          created_by_id: admin.id,
          active: true
        })

      found = Admin.get_announcement!(announcement.id)
      assert found.title == "Get Test"
      assert found.created_by.username == "adminuser"
    end

    test "create_announcement/1 with valid data creates an announcement", %{admin: admin} do
      valid_attrs = %{
        title: "New Feature",
        content: "We've added a new feature!",
        type: "feature",
        created_by_id: admin.id,
        active: true
      }

      assert {:ok, announcement} = Admin.create_announcement(valid_attrs)
      assert announcement.title == "New Feature"
      assert announcement.content == "We've added a new feature!"
      assert announcement.type == "feature"
      assert announcement.active == true
    end

    test "create_announcement/1 with invalid data returns error changeset", %{admin: admin} do
      invalid_attrs = %{
        title: "",
        content: "",
        type: "invalid",
        created_by_id: admin.id
      }

      assert {:error, %Ecto.Changeset{}} = Admin.create_announcement(invalid_attrs)
    end

    test "update_announcement/2 with valid data updates the announcement", %{admin: admin} do
      {:ok, announcement} =
        Admin.create_announcement(%{
          title: "Original Title",
          content: "Original content",
          type: "info",
          created_by_id: admin.id,
          active: true
        })

      update_attrs = %{
        title: "Updated Title",
        content: "Updated content",
        type: "warning"
      }

      assert {:ok, updated} = Admin.update_announcement(announcement, update_attrs)
      assert updated.title == "Updated Title"
      assert updated.content == "Updated content"
      assert updated.type == "warning"
    end

    test "delete_announcement/1 deletes the announcement", %{admin: admin} do
      {:ok, announcement} =
        Admin.create_announcement(%{
          title: "To Delete",
          content: "This will be deleted",
          type: "maintenance",
          created_by_id: admin.id,
          active: true
        })

      assert {:ok, _} = Admin.delete_announcement(announcement)

      assert_raise Ecto.NoResultsError, fn ->
        Admin.get_announcement!(announcement.id)
      end
    end

    test "change_announcement/1 returns an announcement changeset", %{admin: admin} do
      {:ok, announcement} =
        Admin.create_announcement(%{
          title: "Changeset Test",
          content: "Test content",
          type: "urgent",
          created_by_id: admin.id,
          active: true
        })

      changeset = Admin.change_announcement(announcement)
      assert %Ecto.Changeset{} = changeset
    end

    test "dismiss_announcement_for_user/2 creates a dismissal record", %{admin: admin} do
      {:ok, announcement} =
        Admin.create_announcement(%{
          title: "Dismissal Test",
          content: "This will be dismissed",
          type: "info",
          created_by_id: admin.id,
          active: true
        })

      {:ok, other_user} =
        Accounts.create_user(%{
          username: "testuser",
          password: "password123",
          password_confirmation: "password123"
        })

      assert {:ok, _dismissal} =
               Admin.dismiss_announcement_for_user(other_user.id, announcement.id)

      assert Admin.announcement_dismissed_by_user?(other_user.id, announcement.id) == true
      assert Admin.announcement_dismissed_by_user?(admin.id, announcement.id) == false
    end

    test "list_active_announcements_for_user/1 excludes dismissed announcements", %{admin: admin} do
      {:ok, announcement1} =
        Admin.create_announcement(%{
          title: "Announcement 1",
          content: "This will be dismissed",
          type: "info",
          created_by_id: admin.id,
          active: true
        })

      {:ok, _announcement2} =
        Admin.create_announcement(%{
          title: "Announcement 2",
          content: "This will remain visible",
          type: "warning",
          created_by_id: admin.id,
          active: true
        })

      {:ok, user} =
        Accounts.create_user(%{
          username: "testuser2",
          password: "password123",
          password_confirmation: "password123"
        })

      # Before dismissal, both announcements should be visible
      announcements = Admin.list_active_announcements_for_user(user.id)
      assert length(announcements) == 2

      # Dismiss one announcement
      {:ok, _dismissal} = Admin.dismiss_announcement_for_user(user.id, announcement1.id)

      # After dismissal, only one announcement should be visible
      announcements = Admin.list_active_announcements_for_user(user.id)
      assert length(announcements) == 1
      assert hd(announcements).title == "Announcement 2"
    end
  end
end
