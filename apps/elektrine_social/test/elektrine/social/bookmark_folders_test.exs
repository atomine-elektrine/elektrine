defmodule Elektrine.Social.BookmarkFoldersTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Social.BookmarkFolders

  import Elektrine.AccountsFixtures

  describe "bookmark folders" do
    test "creates, lists, updates, and deletes user-owned folders" do
      user = user_fixture()

      assert {:ok, folder} =
               BookmarkFolders.create_folder(user.id, %{"name" => " Research ", "emoji" => " * "})

      assert folder.name == "Research"
      assert folder.emoji == "*"
      assert BookmarkFolders.list_folders(user.id) == [folder]

      assert {:ok, updated} = BookmarkFolders.update_folder(folder, %{"name" => "Archive"})
      assert updated.name == "Archive"

      assert {:ok, _} = BookmarkFolders.delete_folder(updated.id, user.id)
      assert BookmarkFolders.list_folders(user.id) == []
    end

    test "folders are scoped to their owner" do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, folder} = BookmarkFolders.create_folder(user.id, %{"name" => "Private"})

      assert BookmarkFolders.get_folder(folder.id, user.id)
      refute BookmarkFolders.get_folder(folder.id, other_user.id)
      refute BookmarkFolders.folder_belongs_to_user?(folder.id, other_user.id)
    end
  end
end
