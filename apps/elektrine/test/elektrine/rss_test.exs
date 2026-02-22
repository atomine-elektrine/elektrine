defmodule Elektrine.RSSTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  alias Elektrine.RSS
  alias Elektrine.RSS.Feed

  describe "feeds" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "rssuser",
          password: "SecurePassword123!",
          password_confirmation: "SecurePassword123!"
        })

      %{user: user}
    end

    test "get_or_create_feed creates a new feed" do
      url = "https://example.com/feed.xml"

      {:ok, feed} = RSS.get_or_create_feed(url)

      assert feed.url == url
      assert feed.status == "pending"
    end

    test "get_or_create_feed returns existing feed" do
      url = "https://example.com/feed.xml"

      {:ok, feed1} = RSS.get_or_create_feed(url)
      {:ok, feed2} = RSS.get_or_create_feed(url)

      assert feed1.id == feed2.id
    end

    test "get_or_create_feed normalizes URLs" do
      url1 = "  https://example.com/feed.xml  "
      url2 = "https://example.com/feed.xml"

      {:ok, feed1} = RSS.get_or_create_feed(url1)
      {:ok, feed2} = RSS.get_or_create_feed(url2)

      assert feed1.id == feed2.id
    end

    test "get_feed returns feed by ID" do
      {:ok, feed} = RSS.get_or_create_feed("https://example.com/feed.xml")

      found = RSS.get_feed(feed.id)
      assert found.id == feed.id
    end

    test "get_feed returns nil for non-existent ID" do
      assert RSS.get_feed(-1) == nil
    end

    test "get_feed_by_url returns feed by URL" do
      {:ok, feed} = RSS.get_or_create_feed("https://example.com/feed.xml")

      found = RSS.get_feed_by_url("https://example.com/feed.xml")
      assert found.id == feed.id
    end

    test "get_feed_by_url returns nil for non-existent URL" do
      assert RSS.get_feed_by_url("https://nonexistent.com/feed.xml") == nil
    end

    test "update_feed updates feed attributes" do
      {:ok, feed} = RSS.get_or_create_feed("https://example.com/feed.xml")

      {:ok, updated} =
        RSS.update_feed(feed, %{
          title: "Example Feed",
          description: "A test feed",
          status: "active"
        })

      assert updated.title == "Example Feed"
      assert updated.description == "A test feed"
      assert updated.status == "active"
    end

    test "list_stale_feeds returns feeds needing refresh" do
      # Create an active feed with old last_fetched_at
      {:ok, feed} = RSS.get_or_create_feed("https://stale.com/feed.xml")
      old_time = DateTime.add(DateTime.utc_now(), -120, :minute)

      {:ok, feed} =
        RSS.update_feed(feed, %{
          status: "active",
          last_fetched_at: old_time
        })

      stale_feeds = RSS.list_stale_feeds()
      assert Enum.any?(stale_feeds, &(&1.id == feed.id))
    end

    test "list_stale_feeds excludes recently fetched feeds" do
      {:ok, feed} = RSS.get_or_create_feed("https://fresh.com/feed.xml")
      recent_time = DateTime.add(DateTime.utc_now(), -5, :minute)

      {:ok, _feed} =
        RSS.update_feed(feed, %{
          status: "active",
          last_fetched_at: recent_time
        })

      stale_feeds = RSS.list_stale_feeds()
      refute Enum.any?(stale_feeds, &(&1.id == feed.id))
    end
  end

  describe "subscriptions" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "subuser",
          password: "SecurePassword123!",
          password_confirmation: "SecurePassword123!"
        })

      %{user: user}
    end

    test "subscribe creates subscription to feed", %{user: user} do
      url = "https://blog.example.com/feed.xml"

      {:ok, subscription} = RSS.subscribe(user.id, url)

      assert subscription.user_id == user.id
      assert subscription.feed != nil
      assert subscription.feed.url == url
      assert subscription.show_in_timeline == true
    end

    test "subscribe with options", %{user: user} do
      url = "https://blog.example.com/feed.xml"

      {:ok, subscription} =
        RSS.subscribe(user.id, url,
          display_name: "My Blog",
          folder: "Tech"
        )

      assert subscription.display_name == "My Blog"
      assert subscription.folder == "Tech"
    end

    test "subscribe prevents duplicate subscriptions", %{user: user} do
      url = "https://blog.example.com/feed.xml"

      {:ok, _subscription1} = RSS.subscribe(user.id, url)
      {:error, changeset} = RSS.subscribe(user.id, url)

      assert changeset.errors != []
    end

    test "unsubscribe removes subscription", %{user: user} do
      url = "https://blog.example.com/feed.xml"

      {:ok, subscription} = RSS.subscribe(user.id, url)
      {:ok, _} = RSS.unsubscribe(user.id, subscription.feed_id)

      # Verify subscription is gone
      subscriptions = RSS.list_subscriptions(user.id)
      refute Enum.any?(subscriptions, &(&1.feed_id == subscription.feed_id))
    end

    test "unsubscribe returns error when not subscribed", %{user: user} do
      {:error, :not_subscribed} = RSS.unsubscribe(user.id, -1)
    end

    test "list_subscriptions returns user's subscriptions", %{user: user} do
      {:ok, _sub1} = RSS.subscribe(user.id, "https://feed1.com/feed.xml")
      {:ok, _sub2} = RSS.subscribe(user.id, "https://feed2.com/feed.xml")

      subscriptions = RSS.list_subscriptions(user.id)

      assert length(subscriptions) == 2
      assert Enum.all?(subscriptions, &(&1.user_id == user.id))
    end

    test "list_subscriptions preloads feed", %{user: user} do
      {:ok, _sub} = RSS.subscribe(user.id, "https://feed.com/feed.xml")

      [subscription] = RSS.list_subscriptions(user.id)

      assert Ecto.assoc_loaded?(subscription.feed)
      assert subscription.feed.url == "https://feed.com/feed.xml"
    end

    test "list_subscriptions returns empty for user with no subscriptions" do
      {:ok, other_user} =
        Accounts.create_user(%{
          username: "nosubuser",
          password: "SecurePassword123!",
          password_confirmation: "SecurePassword123!"
        })

      assert RSS.list_subscriptions(other_user.id) == []
    end

    test "update_subscription updates subscription settings", %{user: user} do
      {:ok, subscription} = RSS.subscribe(user.id, "https://feed.com/feed.xml")

      {:ok, updated} =
        RSS.update_subscription(subscription, %{
          show_in_timeline: false,
          display_name: "Custom Name"
        })

      assert updated.show_in_timeline == false
      assert updated.display_name == "Custom Name"
    end
  end

  describe "items" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "itemuser",
          password: "SecurePassword123!",
          password_confirmation: "SecurePassword123!"
        })

      {:ok, feed} = RSS.get_or_create_feed("https://items.example.com/feed.xml")
      RSS.update_feed(feed, %{status: "active", title: "Test Feed"})

      %{user: user, feed: feed}
    end

    test "upsert_item creates new item", %{feed: feed} do
      attrs = %{
        guid: "item-1",
        title: "Test Article",
        content: "Article content",
        url: "https://items.example.com/article-1",
        published_at: DateTime.utc_now()
      }

      {:ok, item} = RSS.upsert_item(feed.id, attrs)

      assert item.guid == "item-1"
      assert item.title == "Test Article"
      assert item.feed_id == feed.id
    end

    test "upsert_item updates existing item", %{feed: feed} do
      attrs = %{
        guid: "item-1",
        title: "Original Title",
        content: "Original content"
      }

      {:ok, _item1} = RSS.upsert_item(feed.id, attrs)

      # Update with same guid
      updated_attrs = %{
        guid: "item-1",
        title: "Updated Title",
        content: "Updated content"
      }

      {:ok, item2} = RSS.upsert_item(feed.id, updated_attrs)

      assert item2.title == "Updated Title"
      assert item2.content == "Updated content"

      # Verify only one item exists
      items = RSS.list_feed_items(feed.id)
      assert length(items) == 1
    end

    test "list_feed_items returns items for feed", %{feed: feed} do
      {:ok, _item1} =
        RSS.upsert_item(feed.id, %{guid: "item-1", title: "Article 1"})

      {:ok, _item2} =
        RSS.upsert_item(feed.id, %{guid: "item-2", title: "Article 2"})

      items = RSS.list_feed_items(feed.id)

      assert length(items) == 2
    end

    test "list_feed_items respects limit and offset", %{feed: feed} do
      for i <- 1..5 do
        RSS.upsert_item(feed.id, %{guid: "item-#{i}", title: "Article #{i}"})
      end

      items = RSS.list_feed_items(feed.id, limit: 2, offset: 1)

      assert length(items) == 2
    end

    test "list_user_items returns items from subscribed feeds", %{user: user, feed: feed} do
      # Subscribe and ensure show_in_timeline is true
      {:ok, _subscription} = RSS.subscribe(user.id, feed.url)

      {:ok, _item} =
        RSS.upsert_item(feed.id, %{
          guid: "user-item-1",
          title: "User Item",
          published_at: DateTime.utc_now()
        })

      items = RSS.list_user_items(user.id)

      assert length(items) == 1
      assert hd(items).title == "User Item"
    end

    test "list_user_items excludes items when show_in_timeline is false", %{
      user: user,
      feed: feed
    } do
      {:ok, subscription} = RSS.subscribe(user.id, feed.url)
      {:ok, _subscription} = RSS.update_subscription(subscription, %{show_in_timeline: false})

      {:ok, _item} =
        RSS.upsert_item(feed.id, %{
          guid: "hidden-item",
          title: "Hidden Item",
          published_at: DateTime.utc_now()
        })

      items = RSS.list_user_items(user.id)

      assert items == []
    end

    test "get_timeline_items returns formatted items", %{user: user, feed: feed} do
      # Update feed with title for timeline display
      {:ok, feed} = RSS.update_feed(feed, %{title: "Test Feed", status: "active"})
      {:ok, _subscription} = RSS.subscribe(user.id, feed.url)

      {:ok, _item} =
        RSS.upsert_item(feed.id, %{
          guid: "timeline-item",
          title: "Timeline Article",
          summary: "Article summary",
          url: "https://items.example.com/timeline-article",
          published_at: DateTime.utc_now()
        })

      items = RSS.get_timeline_items(user.id)

      assert length(items) == 1
      [item] = items

      assert item.type == :rss_item
      assert item.title == "Timeline Article"
      assert item.feed_title == "Test Feed"
      assert item.feed_url == feed.url
    end

    test "count_user_items counts all items in subscriptions", %{user: user, feed: feed} do
      {:ok, _subscription} = RSS.subscribe(user.id, feed.url)

      for i <- 1..3 do
        RSS.upsert_item(feed.id, %{guid: "count-item-#{i}", title: "Item #{i}"})
      end

      count = RSS.count_user_items(user.id)
      assert count == 3
    end
  end

  describe "multiple users" do
    setup do
      {:ok, user1} =
        Accounts.create_user(%{
          username: "multiuser1",
          password: "SecurePassword123!",
          password_confirmation: "SecurePassword123!"
        })

      {:ok, user2} =
        Accounts.create_user(%{
          username: "multiuser2",
          password: "SecurePassword123!",
          password_confirmation: "SecurePassword123!"
        })

      %{user1: user1, user2: user2}
    end

    test "users can subscribe to the same feed", %{user1: user1, user2: user2} do
      url = "https://shared.example.com/feed.xml"

      {:ok, sub1} = RSS.subscribe(user1.id, url)
      {:ok, sub2} = RSS.subscribe(user2.id, url)

      # Both subscriptions should exist
      assert sub1.feed_id == sub2.feed_id
      assert sub1.user_id != sub2.user_id
    end

    test "subscription settings are independent per user", %{user1: user1, user2: user2} do
      url = "https://shared.example.com/feed.xml"

      {:ok, sub1} = RSS.subscribe(user1.id, url, display_name: "User 1 Name")
      {:ok, _sub2} = RSS.subscribe(user2.id, url, display_name: "User 2 Name")

      # Update user1's subscription
      {:ok, _updated} = RSS.update_subscription(sub1, %{show_in_timeline: false})

      # User2's subscription should be unchanged
      [user2_sub] = RSS.list_subscriptions(user2.id)
      assert user2_sub.show_in_timeline == true
      assert user2_sub.display_name == "User 2 Name"
    end

    test "user items are isolated", %{user1: user1, user2: user2} do
      {:ok, feed1} = RSS.get_or_create_feed("https://feed1.example.com/feed.xml")
      {:ok, feed2} = RSS.get_or_create_feed("https://feed2.example.com/feed.xml")

      RSS.update_feed(feed1, %{status: "active"})
      RSS.update_feed(feed2, %{status: "active"})

      # User1 subscribes to feed1
      {:ok, _sub1} = RSS.subscribe(user1.id, feed1.url)
      # User2 subscribes to feed2
      {:ok, _sub2} = RSS.subscribe(user2.id, feed2.url)

      # Add items to both feeds
      {:ok, _item1} =
        RSS.upsert_item(feed1.id, %{
          guid: "f1-item",
          title: "Feed 1 Item",
          published_at: DateTime.utc_now()
        })

      {:ok, _item2} =
        RSS.upsert_item(feed2.id, %{
          guid: "f2-item",
          title: "Feed 2 Item",
          published_at: DateTime.utc_now()
        })

      # User1 should only see feed1 items
      user1_items = RSS.list_user_items(user1.id)
      assert length(user1_items) == 1
      assert hd(user1_items).title == "Feed 1 Item"

      # User2 should only see feed2 items
      user2_items = RSS.list_user_items(user2.id)
      assert length(user2_items) == 1
      assert hd(user2_items).title == "Feed 2 Item"
    end
  end

  describe "feed changesets" do
    test "Feed.fetched_changeset sets fetch timestamp" do
      feed = %Feed{
        id: 1,
        url: "https://test.com/feed.xml",
        last_error: "previous error",
        status: "error"
      }

      changeset = Feed.fetched_changeset(feed)

      assert changeset.changes.last_fetched_at != nil
      assert changeset.changes.status == "active"
      # last_error should be cleared (set to nil)
      assert changeset.changes.last_error == nil
    end

    test "Feed.error_changeset records error" do
      feed = %Feed{id: 1, url: "https://test.com/feed.xml", status: "active"}

      changeset = Feed.error_changeset(feed, "Connection timeout")

      assert changeset.changes.last_error == "Connection timeout"
      assert changeset.changes.status == "error"
    end
  end
end
