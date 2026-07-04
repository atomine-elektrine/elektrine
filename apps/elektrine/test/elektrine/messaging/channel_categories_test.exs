defmodule Elektrine.Messaging.ChannelCategoriesTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias Elektrine.Messaging.ChannelCategories
  alias Elektrine.Messaging.ChannelCategory
  alias Elektrine.Messaging.ChatConversation
  alias Elektrine.Repo

  defp create_server_with_member do
    owner = AccountsFixtures.user_fixture()
    member = AccountsFixtures.user_fixture()

    {:ok, server} =
      Messaging.create_server(owner.id, %{name: "category-space", is_public: true})

    {:ok, _member} = Messaging.join_server(server.id, member.id)

    %{owner: owner, member: member, server: server}
  end

  describe "create_category/3" do
    test "owner can create categories with auto-incrementing positions" do
      %{owner: owner, server: server} = create_server_with_member()

      assert {:ok, %ChannelCategory{} = first} =
               ChannelCategories.create_category(server.id, owner.id, %{name: "Text"})

      assert first.name == "Text"
      assert first.position == 0
      assert first.server_id == server.id

      assert {:ok, second} =
               ChannelCategories.create_category(server.id, owner.id, %{name: "Projects"})

      assert second.position == 1
    end

    test "regular members are denied" do
      %{member: member, server: server} = create_server_with_member()

      assert {:error, :unauthorized} =
               ChannelCategories.create_category(server.id, member.id, %{name: "Nope"})
    end

    test "non-members are denied" do
      %{server: server} = create_server_with_member()
      outsider = AccountsFixtures.user_fixture()

      assert {:error, :unauthorized} =
               ChannelCategories.create_category(server.id, outsider.id, %{name: "Nope"})
    end

    test "requires a name" do
      %{owner: owner, server: server} = create_server_with_member()

      assert {:error, %Ecto.Changeset{}} =
               ChannelCategories.create_category(server.id, owner.id, %{})
    end

    test "unknown server returns not_found" do
      owner = AccountsFixtures.user_fixture()

      assert {:error, :not_found} =
               ChannelCategories.create_category(-1, owner.id, %{name: "Ghost"})
    end
  end

  describe "rename_category/3" do
    test "owner can rename, member cannot" do
      %{owner: owner, member: member, server: server} = create_server_with_member()

      {:ok, category} = ChannelCategories.create_category(server.id, owner.id, %{name: "Old"})

      assert {:ok, renamed} = ChannelCategories.rename_category(category.id, owner.id, "New")
      assert renamed.name == "New"

      assert {:error, :unauthorized} =
               ChannelCategories.rename_category(category.id, member.id, "Sneaky")
    end
  end

  describe "delete_category/2" do
    test "deleting a category keeps its channels and nullifies category_id" do
      %{owner: owner, server: server} = create_server_with_member()

      {:ok, category} = ChannelCategories.create_category(server.id, owner.id, %{name: "Temp"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "keepme",
          category_id: category.id
        })

      assert channel.category_id == category.id

      assert {:ok, _deleted} = ChannelCategories.delete_category(category.id, owner.id)

      refute Repo.get(ChannelCategory, category.id)

      reloaded_channel = Repo.get(ChatConversation, channel.id)
      assert reloaded_channel
      assert is_nil(reloaded_channel.category_id)
    end

    test "member cannot delete" do
      %{owner: owner, member: member, server: server} = create_server_with_member()

      {:ok, category} = ChannelCategories.create_category(server.id, owner.id, %{name: "Keep"})

      assert {:error, :unauthorized} = ChannelCategories.delete_category(category.id, member.id)
      assert Repo.get(ChannelCategory, category.id)
    end
  end

  describe "reorder_categories/3" do
    test "sets positions to match the given order" do
      %{owner: owner, server: server} = create_server_with_member()

      {:ok, a} = ChannelCategories.create_category(server.id, owner.id, %{name: "A"})
      {:ok, b} = ChannelCategories.create_category(server.id, owner.id, %{name: "B"})
      {:ok, c} = ChannelCategories.create_category(server.id, owner.id, %{name: "C"})

      assert {:ok, reordered} =
               ChannelCategories.reorder_categories(server.id, owner.id, [c.id, a.id, b.id])

      assert Enum.map(reordered, & &1.id) == [c.id, a.id, b.id]
      assert Enum.map(reordered, & &1.position) == [0, 1, 2]
    end

    test "ignores foreign ids and appends categories missing from the list" do
      %{owner: owner, server: server} = create_server_with_member()

      {:ok, a} = ChannelCategories.create_category(server.id, owner.id, %{name: "A"})
      {:ok, b} = ChannelCategories.create_category(server.id, owner.id, %{name: "B"})

      assert {:ok, reordered} =
               ChannelCategories.reorder_categories(server.id, owner.id, [b.id, -5])

      assert Enum.map(reordered, & &1.id) == [b.id, a.id]
    end

    test "member cannot reorder" do
      %{owner: owner, member: member, server: server} = create_server_with_member()

      {:ok, a} = ChannelCategories.create_category(server.id, owner.id, %{name: "A"})

      assert {:error, :unauthorized} =
               ChannelCategories.reorder_categories(server.id, member.id, [a.id])
    end
  end

  describe "assign_channel_to_category/3" do
    test "assigns and clears a channel's category" do
      %{owner: owner, server: server} = create_server_with_member()

      {:ok, category} = ChannelCategories.create_category(server.id, owner.id, %{name: "Text"})
      {:ok, channel} = Messaging.create_server_channel(server.id, owner.id, %{name: "movable"})

      assert is_nil(channel.category_id)

      assert {:ok, updated} =
               ChannelCategories.assign_channel_to_category(channel.id, owner.id, category.id)

      assert updated.category_id == category.id

      assert {:ok, cleared} =
               ChannelCategories.assign_channel_to_category(channel.id, owner.id, nil)

      assert is_nil(cleared.category_id)
    end

    test "rejects categories from a different server" do
      %{owner: owner, server: server} = create_server_with_member()
      other_owner = AccountsFixtures.user_fixture()

      {:ok, other_server} = Messaging.create_server(other_owner.id, %{name: "other-space"})

      {:ok, foreign_category} =
        ChannelCategories.create_category(other_server.id, other_owner.id, %{name: "Foreign"})

      {:ok, channel} = Messaging.create_server_channel(server.id, owner.id, %{name: "here"})

      assert {:error, :category_not_in_server} =
               ChannelCategories.assign_channel_to_category(
                 channel.id,
                 owner.id,
                 foreign_category.id
               )
    end

    test "member cannot assign channels" do
      %{owner: owner, member: member, server: server} = create_server_with_member()

      {:ok, category} = ChannelCategories.create_category(server.id, owner.id, %{name: "Text"})
      {:ok, channel} = Messaging.create_server_channel(server.id, owner.id, %{name: "locked"})

      assert {:error, :unauthorized} =
               ChannelCategories.assign_channel_to_category(channel.id, member.id, category.id)
    end
  end

  describe "listing" do
    test "list_categories orders by position" do
      %{owner: owner, server: server} = create_server_with_member()

      {:ok, a} = ChannelCategories.create_category(server.id, owner.id, %{name: "A"})
      {:ok, b} = ChannelCategories.create_category(server.id, owner.id, %{name: "B"})
      {:ok, _} = ChannelCategories.reorder_categories(server.id, owner.id, [b.id, a.id])

      assert Enum.map(ChannelCategories.list_categories(server.id), & &1.id) == [b.id, a.id]
    end

    test "list_categories_with_channels groups and orders channels" do
      %{owner: owner, server: server} = create_server_with_member()

      {:ok, category} = ChannelCategories.create_category(server.id, owner.id, %{name: "Text"})

      {:ok, second_channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "beta",
          category_id: category.id
        })

      {:ok, first_channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "alpha",
          category_id: category.id,
          channel_position: 0
        })

      {categories, uncategorized} =
        ChannelCategories.list_categories_with_channels(server.id)

      assert [%ChannelCategory{id: category_id, channels: channels}] = categories
      assert category_id == category.id

      assert Enum.map(channels, & &1.id) == [first_channel.id, second_channel.id]

      # The default "general" channel stays uncategorized.
      assert Enum.map(uncategorized, & &1.name) == ["general"]
    end
  end

  describe "create_server_channel/3 category handling" do
    test "accepts a category from the same server and drops foreign ones" do
      %{owner: owner, server: server} = create_server_with_member()
      other_owner = AccountsFixtures.user_fixture()

      {:ok, category} = ChannelCategories.create_category(server.id, owner.id, %{name: "Text"})
      {:ok, other_server} = Messaging.create_server(other_owner.id, %{name: "elsewhere"})

      {:ok, foreign_category} =
        ChannelCategories.create_category(other_server.id, other_owner.id, %{name: "Foreign"})

      {:ok, channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "categorized",
          category_id: category.id
        })

      assert channel.category_id == category.id

      {:ok, other_channel} =
        Messaging.create_server_channel(server.id, owner.id, %{
          name: "uncategorized",
          category_id: foreign_category.id
        })

      assert is_nil(other_channel.category_id)
    end
  end
end
