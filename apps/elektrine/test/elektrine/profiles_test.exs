defmodule Elektrine.ProfilesTest do
  @moduledoc """
  Tests for the Profiles context, including profile creation,
  lookup by handle, and follow/unfollow functionality.
  """
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Profiles.{ProfileSiteVisit, ProfileView, SitePageVisit, SiteSession}
  alias Elektrine.Repo

  describe "get_profile_by_handle/1" do
    test "returns profile for valid handle" do
      user = AccountsFixtures.user_fixture()

      {:ok, profile} =
        Profiles.create_user_profile(user.id, %{
          display_name: "Test User",
          is_public: true
        })

      found_profile = Profiles.get_profile_by_handle(user.handle)

      assert found_profile.id == profile.id
      assert found_profile.user.handle == user.handle
    end

    test "returns nil for non-existent handle" do
      assert Profiles.get_profile_by_handle("nonexistent_handle") == nil
    end

    test "returns nil for private profiles" do
      user = AccountsFixtures.user_fixture()

      {:ok, _profile} =
        Profiles.create_user_profile(user.id, %{
          display_name: "Private User",
          is_public: false
        })

      assert Profiles.get_profile_by_handle(user.handle) == nil
    end

    test "preloads user association" do
      user = AccountsFixtures.user_fixture()

      {:ok, _profile} =
        Profiles.create_user_profile(user.id, %{
          display_name: "Test User",
          is_public: true
        })

      found_profile = Profiles.get_profile_by_handle(user.handle)

      assert Ecto.assoc_loaded?(found_profile.user)
      assert found_profile.user.id == user.id
    end

    test "preloads active links ordered by position" do
      user = AccountsFixtures.user_fixture()

      {:ok, profile} =
        Profiles.create_user_profile(user.id, %{
          display_name: "Test User",
          is_public: true
        })

      # Create some profile links
      {:ok, _link1} =
        Profiles.create_profile_link(profile.id, %{
          title: "Link 1",
          url: "https://example.com/1",
          position: 2,
          is_active: true
        })

      {:ok, _link2} =
        Profiles.create_profile_link(profile.id, %{
          title: "Link 2",
          url: "https://example.com/2",
          position: 1,
          is_active: true
        })

      {:ok, _inactive_link} =
        Profiles.create_profile_link(profile.id, %{
          title: "Inactive Link",
          url: "https://example.com/inactive",
          position: 0,
          is_active: false
        })

      found_profile = Profiles.get_profile_by_handle(user.handle)

      assert Ecto.assoc_loaded?(found_profile.links)
      # Should only have active links
      assert length(found_profile.links) == 2
      # Should be ordered by position
      assert Enum.at(found_profile.links, 0).title == "Link 2"
      assert Enum.at(found_profile.links, 1).title == "Link 1"
    end
  end

  describe "profile links" do
    test "rejects unsafe and malformed profile link URLs" do
      user = AccountsFixtures.user_fixture()
      {:ok, profile} = Profiles.create_user_profile(user.id, %{display_name: "Link User"})

      unsafe_urls = [
        "javascript:alert(1)",
        "data:text/html,<script>alert(1)</script>",
        "https://example.com\r\nLocation:https://evil.test",
        "https://example.com/some path",
        "mailto:test@example.com\r\nBcc:evil@example.com",
        "mailto:not-an-address",
        "tel:+1 555 123 4567",
        "tel:abc123"
      ]

      for url <- unsafe_urls do
        assert {:error, changeset} =
                 Profiles.create_profile_link(profile.id, %{
                   title: "Unsafe",
                   url: url,
                   platform: "website"
                 })

        assert %{url: [_ | _]} = errors_on(changeset)
      end
    end

    test "accepts trimmed http, mailto, and tel profile link URLs" do
      user = AccountsFixtures.user_fixture()
      {:ok, profile} = Profiles.create_user_profile(user.id, %{display_name: "Link User"})

      assert {:ok, link} =
               Profiles.create_profile_link(profile.id, %{
                 title: "Site",
                 url: " https://example.com/path?x=1 ",
                 platform: "website"
               })

      assert link.url == "https://example.com/path?x=1"

      assert {:ok, _link} =
               Profiles.create_profile_link(profile.id, %{
                 title: "Email",
                 url: "mailto:test@example.com",
                 platform: "email"
               })

      assert {:ok, _link} =
               Profiles.create_profile_link(profile.id, %{
                 title: "Phone",
                 url: "tel:+15551234567",
                 platform: "phone"
               })
    end
  end

  describe "profile uploaded media URLs" do
    test "rejects absolute URLs that only look like local uploads" do
      user = AccountsFixtures.user_fixture()

      assert {:error, changeset} =
               Profiles.create_user_profile(user.id, %{
                 display_name: "Media User",
                 avatar_url: "https://evil.example/uploads/avatars/avatar.png",
                 background_url: "https://evil.example/uploads/backgrounds/bg.png",
                 banner_url: "https://evil.example/uploads/backgrounds/banner.png",
                 favicon_url: "https://evil.example/uploads/favicons/favicon.ico"
               })

      assert %{avatar_url: [_ | _]} = errors_on(changeset)
      assert %{background_url: [_ | _]} = errors_on(changeset)
      assert %{banner_url: [_ | _]} = errors_on(changeset)
      assert %{favicon_url: [_ | _]} = errors_on(changeset)
    end

    test "accepts relative upload keys and paths for profile media" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, profile} =
               Profiles.create_user_profile(user.id, %{
                 display_name: "Media User",
                 avatar_url: "avatars/avatar.png",
                 background_url: "/uploads/backgrounds/bg.png",
                 banner_url: "uploads/backgrounds/banner.png",
                 favicon_url: "favicons/favicon.ico"
               })

      assert profile.avatar_url == "avatars/avatar.png"
      assert profile.background_url == "/uploads/backgrounds/bg.png"
      assert profile.banner_url == "uploads/backgrounds/banner.png"
      assert profile.favicon_url == "favicons/favicon.ico"
    end
  end

  describe "follow_user/2" do
    test "creates a follow relationship" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      assert {:ok, _follow} = Profiles.follow_user(user1.id, user2.id)
      assert Profiles.following?(user1.id, user2.id)
    end

    test "cannot follow self" do
      user = AccountsFixtures.user_fixture()

      _result = Profiles.follow_user(user.id, user.id)

      # Should either return error or silently fail
      refute Profiles.following?(user.id, user.id)
    end

    test "following same user twice is idempotent" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user1.id, user2.id)
      _result = Profiles.follow_user(user1.id, user2.id)

      # Should either succeed or return already following
      assert Profiles.following?(user1.id, user2.id)
    end
  end

  describe "unfollow_user/2" do
    test "removes a follow relationship" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user1.id, user2.id)
      assert Profiles.following?(user1.id, user2.id)

      assert {:ok, :unfollowed} = Profiles.unfollow_user(user1.id, user2.id)
      refute Profiles.following?(user1.id, user2.id)
    end

    test "unfollowing when not following is a no-op" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      assert {:ok, :not_following} = Profiles.unfollow_user(user1.id, user2.id)
      refute Profiles.following?(user1.id, user2.id)
    end
  end

  describe "following?/2" do
    test "returns true when following" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user1.id, user2.id)

      assert Profiles.following?(user1.id, user2.id)
    end

    test "returns false when not following" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      refute Profiles.following?(user1.id, user2.id)
    end

    test "follow relationship is directional" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user1.id, user2.id)

      assert Profiles.following?(user1.id, user2.id)
      refute Profiles.following?(user2.id, user1.id)
    end
  end

  describe "remote follow identity helpers" do
    test "resolve pending follow state from a remote actor struct" do
      viewer = AccountsFixtures.user_fixture()

      actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://mastodon.example/users/pending-remote",
          username: "pending-remote",
          domain: "mastodon.example",
          inbox_url: "https://mastodon.example/users/pending-remote/inbox",
          public_key: "test-public-key-pending-remote",
          manually_approves_followers: true
        })
        |> Repo.insert!()

      %Follow{}
      |> Ecto.Changeset.change(%{
        follower_id: viewer.id,
        remote_actor_id: actor.id,
        activitypub_id: "https://elektrine.test/follows/#{System.unique_integer([:positive])}",
        pending: true
      })
      |> Repo.insert!()

      assert %{pending: true} = Profiles.get_follow_to_remote_actor_by_identity(viewer.id, actor)
      assert not Profiles.following_remote_actor_by_identity?(viewer.id, actor)
    end

    test "ignores nil uri when resolving remote actor identity" do
      viewer = AccountsFixtures.user_fixture()

      actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://mastodon.example/users/no-uri-lookup",
          username: "no-uri-lookup",
          domain: "mastodon.example",
          inbox_url: "https://mastodon.example/users/no-uri-lookup/inbox",
          public_key: "test-public-key-no-uri-lookup",
          manually_approves_followers: true
        })
        |> Repo.insert!()

      %Follow{}
      |> Ecto.Changeset.change(%{
        follower_id: viewer.id,
        remote_actor_id: actor.id,
        activitypub_id: "https://elektrine.test/follows/#{System.unique_integer([:positive])}",
        pending: true
      })
      |> Repo.insert!()

      actor_without_uri = %{
        id: actor.id,
        uri: nil,
        username: actor.username,
        domain: actor.domain
      }

      assert %{pending: true} =
               Profiles.get_follow_to_remote_actor_by_identity(viewer.id, actor_without_uri)

      assert not Profiles.following_remote_actor_by_identity?(viewer.id, actor_without_uri)
    end
  end

  describe "public site analytics" do
    test "empty host lists do not fall back to global analytics" do
      track_site_visit("analytics-empty.example", "/", "empty-a")

      assert Profiles.get_public_site_view_count([]) == 0
      assert Profiles.get_public_site_unique_visitor_count([]) == 0
      assert Profiles.get_public_site_session_count([]) == 0
      assert Profiles.get_public_site_top_pages([], 10) == []
      assert Profiles.get_public_site_top_referrers([], 10) == []
      assert Profiles.get_public_site_domain_breakdown([]) == []

      stats = Profiles.get_public_site_view_stats([])

      assert stats.total_views == 0
      assert stats.unique_visitors == 0
      assert stats.sessions == 0
      assert stats.views_today == 0
      assert stats.views_this_week == 0
    end

    test "public site stats aggregate a selected host" do
      session_id = unique_session_id("analytics-host")

      track_site_visit("analytics-host.example", "/", "host-a", session_id)
      track_site_visit("analytics-host.example", "/pricing", "host-a", session_id)
      track_site_visit("other-analytics-host.example", "/", "host-b")

      stats = Profiles.get_public_site_view_stats("analytics-host.example")

      assert stats.total_views == 2
      assert stats.unique_visitors == 1
      assert stats.sessions == 1
      assert stats.views_today == 2
      assert stats.views_this_week == 2
      assert stats.bounce_rate == 0.0
    end
  end

  describe "get_follower_count/1" do
    test "returns 0 for user with no followers" do
      user = AccountsFixtures.user_fixture()
      assert Profiles.get_follower_count(user.id) == 0
    end

    test "returns correct count" do
      user = AccountsFixtures.user_fixture()
      follower1 = AccountsFixtures.user_fixture()
      follower2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(follower1.id, user.id)
      {:ok, _} = Profiles.follow_user(follower2.id, user.id)

      assert Profiles.get_follower_count(user.id) == 2
    end
  end

  describe "get_following_count/1" do
    test "returns 0 for user following no one" do
      user = AccountsFixtures.user_fixture()
      assert Profiles.get_following_count(user.id) == 0
    end

    test "returns correct count" do
      user = AccountsFixtures.user_fixture()
      target1 = AccountsFixtures.user_fixture()
      target2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user.id, target1.id)
      {:ok, _} = Profiles.follow_user(user.id, target2.id)

      assert Profiles.get_following_count(user.id) == 2
    end
  end

  describe "get_followers/1" do
    test "returns list of followers" do
      user = AccountsFixtures.user_fixture()
      follower1 = AccountsFixtures.user_fixture()
      follower2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(follower1.id, user.id)
      {:ok, _} = Profiles.follow_user(follower2.id, user.id)

      followers = Profiles.get_followers(user.id)

      assert length(followers) == 2
      follower_ids = Enum.map(followers, & &1.user.id)
      assert follower1.id in follower_ids
      assert follower2.id in follower_ids
    end

    test "returns empty list when no followers" do
      user = AccountsFixtures.user_fixture()
      assert Profiles.get_followers(user.id) == []
    end

    test "supports id pagination options" do
      user = AccountsFixtures.user_fixture()
      older = AccountsFixtures.user_fixture()
      newer = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(older.id, user.id)
      {:ok, _} = Profiles.follow_user(newer.id, user.id)

      followers = Profiles.get_followers(user.id, before_id: newer.id)
      assert Enum.map(followers, & &1.user.id) == [older.id]

      followers = Profiles.get_followers(user.id, since_id: older.id)
      assert Enum.map(followers, & &1.user.id) == [newer.id]
    end
  end

  describe "get_following/1" do
    test "returns list of users being followed" do
      user = AccountsFixtures.user_fixture()
      target1 = AccountsFixtures.user_fixture()
      target2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user.id, target1.id)
      {:ok, _} = Profiles.follow_user(user.id, target2.id)

      following = Profiles.get_following(user.id)

      assert length(following) == 2
      following_ids = Enum.map(following, & &1.user.id)
      assert target1.id in following_ids
      assert target2.id in following_ids
    end

    test "returns empty list when not following anyone" do
      user = AccountsFixtures.user_fixture()
      assert Profiles.get_following(user.id) == []
    end

    test "supports id pagination options" do
      user = AccountsFixtures.user_fixture()
      older = AccountsFixtures.user_fixture()
      newer = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user.id, older.id)
      {:ok, _} = Profiles.follow_user(user.id, newer.id)

      following = Profiles.get_following(user.id, before_id: newer.id)
      assert Enum.map(following, & &1.user.id) == [older.id]

      following = Profiles.get_following(user.id, since_id: older.id)
      assert Enum.map(following, & &1.user.id) == [newer.id]
    end
  end

  describe "list_remote_followers/1" do
    test "returns only accepted remote followers" do
      user = AccountsFixtures.user_fixture()
      accepted_actor = remote_actor_fixture("accepted")
      pending_actor = remote_actor_fixture("pending")

      {:ok, _} =
        Profiles.create_remote_follow(
          accepted_actor.id,
          user.id,
          false,
          "https://remote.server/activities/follow/#{System.unique_integer([:positive])}"
        )

      {:ok, _} =
        Profiles.create_remote_follow(
          pending_actor.id,
          user.id,
          true,
          "https://remote.server/activities/follow/#{System.unique_integer([:positive])}"
        )

      followers = Profiles.list_remote_followers(user.id)
      follower_actor_ids = Enum.map(followers, & &1.remote_actor_id)

      assert accepted_actor.id in follower_actor_ids
      refute pending_actor.id in follower_actor_ids
      assert length(follower_actor_ids) == 1
    end
  end

  describe "remote follow status" do
    test "treats legacy pending follows to auto-accepting remote actors as following" do
      user = AccountsFixtures.user_fixture()
      auto_accepting_actor = remote_actor_fixture("public", %{manually_approves_followers: false})

      approval_required_actor =
        remote_actor_fixture("private", %{manually_approves_followers: true})

      insert_local_to_remote_follow(user.id, auto_accepting_actor.id, true)
      insert_local_to_remote_follow(user.id, approval_required_actor.id, true)

      assert Profiles.following_remote_actor?(user.id, auto_accepting_actor.id)
      refute Profiles.following_remote_actor?(user.id, approval_required_actor.id)

      assert Profiles.remote_following_status_batch(user.id, [
               auto_accepting_actor.id,
               approval_required_actor.id
             ]) == [
               {auto_accepting_actor.id, :following},
               {approval_required_actor.id, :pending}
             ]

      following = Profiles.get_following(user.id)

      assert Enum.any?(
               following,
               &(&1.type == "remote" and &1.remote_actor.id == auto_accepting_actor.id)
             )

      refute Enum.any?(
               following,
               &(&1.type == "remote" and &1.remote_actor.id == approval_required_actor.id)
             )

      assert Profiles.get_following_count(user.id) == 1
    end
  end

  describe "site visit analytics" do
    test "skips known bot user agents for public site analytics" do
      assert {:ok, :bot} =
               Profiles.track_site_page_visit(
                 visitor_id: "bot-visitor",
                 session_id: "bot-session",
                 request_host: "example.com",
                 request_path: "/",
                 status: 200,
                 user_agent:
                   "Mozilla/5.0 AppleWebKit/537.36 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)"
               )

      assert Repo.aggregate(SitePageVisit, :count) == 0
      assert Repo.aggregate(SiteSession, :count) == 0
    end

    test "skips known bot user agents for profile analytics" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, :bot} =
               Profiles.track_profile_view(user.id,
                 viewer_session_id: "bot-profile-session",
                 user_agent: "Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)"
               )

      assert {:ok, :bot} =
               Profiles.track_profile_site_visit(user.id,
                 visitor_id: "bot-site-visitor",
                 request_host: "example.com",
                 request_path: "/",
                 user_agent:
                   "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
               )

      assert Repo.aggregate(ProfileView, :count) == 0
      assert Repo.aggregate(ProfileSiteVisit, :count) == 0
    end

    test "can scope stats to multiple hosts" do
      user = AccountsFixtures.user_fixture()

      {:ok, _} =
        Profiles.track_profile_site_visit(user.id,
          visitor_id: "visitor-1",
          request_host: "example.com",
          request_path: "/"
        )

      {:ok, _} =
        Profiles.track_profile_site_visit(user.id,
          visitor_id: "visitor-2",
          request_host: "www.example.com",
          request_path: "/about"
        )

      {:ok, _} =
        Profiles.track_profile_site_visit(user.id,
          visitor_id: "visitor-3",
          request_host: "other.example.net",
          request_path: "/"
        )

      stats = Profiles.get_site_view_stats(user.id, ["example.com", "www.example.com"])

      assert stats.total_views == 2
      assert stats.unique_visitors == 2
      assert stats.views_today == 2
      assert stats.views_this_week == 2
    end

    test "prunes raw analytics rows past configured retention windows" do
      user = AccountsFixtures.user_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      old_site_datetime = DateTime.add(now, -31, :day)
      recent_site_datetime = DateTime.add(now, -29, :day)
      old_profile_datetime = DateTime.add(now, -91, :day)
      recent_profile_datetime = DateTime.add(now, -89, :day)
      old_site_timestamp = DateTime.to_naive(old_site_datetime)
      recent_site_timestamp = DateTime.to_naive(recent_site_datetime)
      old_profile_timestamp = DateTime.to_naive(old_profile_datetime)
      recent_profile_timestamp = DateTime.to_naive(recent_profile_datetime)

      Repo.insert_all(SitePageVisit, [
        %{
          visitor_id: "old-page-visitor",
          session_id: "old-page-session",
          request_host: "example.com",
          request_path: "/old",
          status: 200,
          inserted_at: old_site_timestamp
        },
        %{
          visitor_id: "recent-page-visitor",
          session_id: "recent-page-session",
          request_host: "example.com",
          request_path: "/recent",
          status: 200,
          inserted_at: recent_site_timestamp
        }
      ])

      Repo.insert_all(SiteSession, [
        %{
          session_id: "old-session",
          visitor_id: "old-session-visitor",
          entry_host: "example.com",
          entry_path: "/old",
          exit_host: "example.com",
          exit_path: "/old",
          page_views: 1,
          started_at: old_site_datetime,
          last_seen_at: old_site_datetime,
          duration_seconds: 0,
          inserted_at: old_site_timestamp,
          updated_at: old_site_timestamp
        },
        %{
          session_id: "recent-session",
          visitor_id: "recent-session-visitor",
          entry_host: "example.com",
          entry_path: "/recent",
          exit_host: "example.com",
          exit_path: "/recent",
          page_views: 1,
          started_at: recent_site_datetime,
          last_seen_at: recent_site_datetime,
          duration_seconds: 0,
          inserted_at: recent_site_timestamp,
          updated_at: recent_site_timestamp
        }
      ])

      Repo.insert_all(ProfileSiteVisit, [
        %{
          profile_user_id: user.id,
          visitor_id: "old-profile-site-visitor",
          request_host: "example.com",
          request_path: "/old",
          inserted_at: old_profile_timestamp
        },
        %{
          profile_user_id: user.id,
          visitor_id: "recent-profile-site-visitor",
          request_host: "example.com",
          request_path: "/recent",
          inserted_at: recent_profile_timestamp
        }
      ])

      Repo.insert_all(ProfileView, [
        %{
          profile_user_id: user.id,
          viewer_session_id: "old-profile-view-session",
          inserted_at: old_profile_timestamp
        },
        %{
          profile_user_id: user.id,
          viewer_session_id: "recent-profile-view-session",
          inserted_at: recent_profile_timestamp
        }
      ])

      assert %{
               site_page_visits: 1,
               site_sessions: 1,
               profile_site_visits: 1,
               profile_views: 1
             } =
               Profiles.prune_analytics_retention(
                 site_retention_days: 30,
                 profile_retention_days: 90,
                 batch_size: 10,
                 max_batches: 10,
                 now: now
               )

      assert Repo.aggregate(SitePageVisit, :count) == 1
      assert Repo.aggregate(SiteSession, :count) == 1
      assert Repo.aggregate(ProfileSiteVisit, :count) == 1
      assert Repo.aggregate(ProfileView, :count) == 1

      assert Repo.get_by(SitePageVisit, request_path: "/recent")
      assert Repo.get_by(SiteSession, session_id: "recent-session")
      assert Repo.get_by(ProfileSiteVisit, request_path: "/recent")
      assert Repo.get_by(ProfileView, viewer_session_id: "recent-profile-view-session")
    end

    test "serves public site analytics from refreshed rollups" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      today_timestamp = DateTime.to_naive(now)
      yesterday = DateTime.add(now, -1, :day)
      yesterday_timestamp = DateTime.to_naive(yesterday)

      Repo.insert_all(SiteSession, [
        %{
          session_id: unique_session_id("rollup-home"),
          visitor_id: "rollup-home-visitor",
          referer: "https://referrer.example",
          entry_host: "example.com",
          entry_path: "/",
          exit_host: "example.com",
          exit_path: "/",
          page_views: 3,
          started_at: now,
          last_seen_at: now,
          duration_seconds: 20,
          inserted_at: today_timestamp,
          updated_at: today_timestamp
        },
        %{
          session_id: unique_session_id("rollup-about"),
          visitor_id: "rollup-about-visitor",
          entry_host: "example.com",
          entry_path: "/about",
          exit_host: "example.com",
          exit_path: "/about",
          page_views: 1,
          started_at: yesterday,
          last_seen_at: yesterday,
          duration_seconds: 10,
          inserted_at: yesterday_timestamp,
          updated_at: yesterday_timestamp
        },
        %{
          session_id: unique_session_id("rollup-other-host"),
          visitor_id: "rollup-other-host-visitor",
          entry_host: "other.example",
          entry_path: "/",
          exit_host: "other.example",
          exit_path: "/",
          page_views: 5,
          started_at: now,
          last_seen_at: now,
          duration_seconds: 30,
          inserted_at: today_timestamp,
          updated_at: today_timestamp
        }
      ])

      assert %{daily: 3, pages: 3, referrers: 1, dates: 30} =
               Profiles.refresh_public_site_analytics_rollups(days: 30)

      Repo.delete_all(SiteSession)

      stats = Profiles.get_public_site_view_stats("example.com")
      assert stats.total_views == 4
      assert stats.sessions == 2
      assert stats.unique_visitors == 2
      assert stats.views_today == 3
      assert stats.views_this_week == 4
      assert stats.avg_session_duration_seconds == 15.0
      assert stats.bounce_rate == 50.0

      assert [%{host: "example.com", path: "/", views: 3, unique_visitors: 1} | _] =
               Profiles.get_public_site_top_pages("example.com", 10)

      assert [%{referer: "https://referrer.example", count: 1}] =
               Profiles.get_public_site_top_referrers("example.com", 10)

      assert [%{host: "example.com", views: 4, unique_visitors: 2, views_today: 3}] =
               Profiles.get_public_site_domain_breakdown(["example.com"])

      daily_views = Profiles.get_public_site_daily_view_counts(2, "example.com")
      assert Enum.map(daily_views, & &1.count) == [1, 3]
    end
  end

  defp remote_actor_fixture(label, overrides \\ %{}) do
    unique_id = System.unique_integer([:positive])
    username = "#{label}_#{unique_id}"

    %Actor{}
    |> Actor.changeset(
      Map.merge(
        %{
          uri: "https://remote.server/users/#{username}",
          username: username,
          domain: "remote.server",
          inbox_url: "https://remote.server/users/#{username}/inbox",
          public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
          last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        overrides
      )
    )
    |> Repo.insert!()
  end

  defp insert_local_to_remote_follow(follower_id, remote_actor_id, pending) do
    %Follow{}
    |> Follow.changeset(%{
      follower_id: follower_id,
      remote_actor_id: remote_actor_id,
      pending: pending,
      activitypub_id: "https://elektrine.example/activities/#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp track_site_visit(host, path, visitor_id, session_id \\ nil) do
    session_id = session_id || unique_session_id(visitor_id)

    {:ok, _visit} =
      Profiles.track_site_page_visit(
        visitor_id: visitor_id,
        session_id: session_id,
        request_host: host,
        request_path: path,
        status: 200
      )

    session_id
  end

  defp unique_session_id(label) do
    "#{label}-#{System.unique_integer([:positive])}"
  end
end
