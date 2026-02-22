defmodule Elektrine.BlueskyInboundTest do
  use Elektrine.DataCase, async: false

  import Ecto.Query
  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Bluesky.Inbound
  alias Elektrine.Bluesky.InboundEvent
  alias Elektrine.Messaging.Message
  alias Elektrine.Notifications.Notification
  alias Elektrine.Repo

  defmodule MockHTTPClient do
    def put_responses(responses), do: Process.put(:bluesky_inbound_mock_responses, responses)
    def clear_responses, do: Process.delete(:bluesky_inbound_mock_responses)
    def clear_requests, do: Process.delete(:bluesky_inbound_mock_requests)

    def requests do
      Process.get(:bluesky_inbound_mock_requests, [])
      |> Enum.reverse()
    end

    def request(method, url, headers, body, opts) do
      request = %{method: method, url: url, headers: headers, body: body, opts: opts}

      Process.put(
        :bluesky_inbound_mock_requests,
        [request | Process.get(:bluesky_inbound_mock_requests, [])]
      )

      case Process.get(:bluesky_inbound_mock_responses, []) do
        [next | rest] ->
          Process.put(:bluesky_inbound_mock_responses, rest)
          next

        [] ->
          {:error, :no_mock_response}
      end
    end
  end

  setup do
    previous = Application.get_env(:elektrine, :bluesky, [])

    Application.put_env(:elektrine, :bluesky,
      enabled: true,
      inbound_enabled: true,
      inbound_limit: 50,
      service_url: "https://bsky.social",
      timeout_ms: 5_000,
      max_chars: 300,
      http_client: MockHTTPClient
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :bluesky, previous)
      MockHTTPClient.clear_requests()
      MockHTTPClient.clear_responses()
    end)

    :ok
  end

  test "sync_user creates local notification for remote Bluesky reply" do
    user = bluesky_user_fixture()
    local_post = mirrored_post_fixture(user, "at://did:plc:local/app.bsky.feed.post/abc")

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:local"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "cursor" => "cursor-2",
             "notifications" => [
               %{
                 "reason" => "reply",
                 "reasonSubject" => local_post.bluesky_uri,
                 "uri" => "at://did:plc:remote/app.bsky.feed.post/reply1",
                 "cid" => "cid-reply1",
                 "author" => %{
                   "did" => "did:plc:remote",
                   "handle" => "remote-user.bsky.social"
                 },
                 "record" => %{"text" => "nice post"}
               }
             ]
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"feed" => []})
       }}
    ])

    assert {:ok, %{processed_events: 1, created_notifications: 1, synced_feed_posts: 0}} =
             Inbound.sync_user(user)

    notifications =
      from(n in Notification,
        where:
          n.user_id == ^user.id and n.source_type == "bluesky" and n.source_id == ^local_post.id
      )
      |> Repo.all()

    assert length(notifications) == 1
    assert hd(notifications).type == "reply"
    assert hd(notifications).title =~ "remote-user.bsky.social"

    inbound_events =
      from(e in InboundEvent,
        where: e.user_id == ^user.id and e.related_post_uri == ^local_post.bluesky_uri
      )
      |> Repo.all()

    assert length(inbound_events) == 1

    refreshed_user = Repo.get!(User, user.id)
    assert refreshed_user.bluesky_inbound_cursor == "cursor-2"
    assert refreshed_user.bluesky_inbound_last_polled_at != nil
  end

  test "duplicate inbound event is deduplicated" do
    user = bluesky_user_fixture()
    local_post = mirrored_post_fixture(user, "at://did:plc:local/app.bsky.feed.post/dup")

    payload = %{
      "cursor" => "cursor-dup",
      "notifications" => [
        %{
          "reason" => "reply",
          "reasonSubject" => local_post.bluesky_uri,
          "uri" => "at://did:plc:remote/app.bsky.feed.post/dup-reply",
          "cid" => "cid-dup-reply",
          "author" => %{
            "did" => "did:plc:remote",
            "handle" => "remote-user.bsky.social"
          },
          "record" => %{"text" => "duplicate event"}
        }
      ]
    }

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:local"})
       }},
      {:ok, %Finch.Response{status: 200, body: Jason.encode!(payload)}},
      {:ok, %Finch.Response{status: 200, body: Jason.encode!(%{"feed" => []})}},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:local"})
       }},
      {:ok, %Finch.Response{status: 200, body: Jason.encode!(payload)}},
      {:ok, %Finch.Response{status: 200, body: Jason.encode!(%{"feed" => []})}}
    ])

    assert {:ok, %{processed_events: 1, created_notifications: 1, synced_feed_posts: 0}} =
             Inbound.sync_user(user)

    assert {:ok, %{processed_events: 0, created_notifications: 0, synced_feed_posts: 0}} =
             Inbound.sync_user(user)

    assert Repo.aggregate(
             from(n in Notification,
               where:
                 n.user_id == ^user.id and n.source_type == "bluesky" and
                   n.source_id == ^local_post.id
             ),
             :count
           ) == 1

    assert Repo.aggregate(from(e in InboundEvent, where: e.user_id == ^user.id), :count) == 1
  end

  test "sync_user stores inbound feed post snapshots" do
    user = bluesky_user_fixture()

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:local"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"cursor" => "cursor-feed", "notifications" => []})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "feed" => [
               %{
                 "post" => %{
                   "uri" => "at://did:plc:remote/app.bsky.feed.post/feed1",
                   "cid" => "feedcid1",
                   "author" => %{"did" => "did:plc:remote", "handle" => "remote.bsky.social"},
                   "record" => %{"text" => "feed text"},
                   "likeCount" => 2,
                   "repostCount" => 1
                 }
               }
             ]
           })
       }}
    ])

    assert {:ok, %{processed_events: 0, created_notifications: 0, synced_feed_posts: 1}} =
             Inbound.sync_user(user)

    feed_events =
      from(e in InboundEvent,
        where:
          e.user_id == ^user.id and e.reason == "feed_post" and
            e.related_post_uri == "at://did:plc:remote/app.bsky.feed.post/feed1"
      )
      |> Repo.all()

    assert length(feed_events) == 1
    assert get_in(hd(feed_events).metadata, ["payload", "record", "text"]) == "feed text"
  end

  defp bluesky_user_fixture(attrs \\ %{}) do
    user = user_fixture()

    defaults = %{
      "bluesky_enabled" => true,
      "bluesky_identifier" => "#{user.username}.bsky.social",
      "bluesky_app_password" => "test-app-password"
    }

    {:ok, updated_user} =
      Accounts.update_user(
        user,
        defaults
        |> Map.merge(attrs)
      )

    updated_user
  end

  defp mirrored_post_fixture(user, bluesky_uri) do
    post = post_fixture(%{user: user, visibility: "public"})

    from(m in Message, where: m.id == ^post.id)
    |> Repo.update_all(set: [bluesky_uri: bluesky_uri, bluesky_cid: "test-cid"])

    Repo.get!(Message, post.id)
  end
end
