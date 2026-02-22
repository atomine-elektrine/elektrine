defmodule Elektrine.BlueskyTest do
  use Elektrine.DataCase, async: false

  import Ecto.Query
  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Bluesky
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  defmodule MockHTTPClient do
    def put_responses(responses), do: Process.put(:bluesky_mock_responses, responses)
    def clear_responses, do: Process.delete(:bluesky_mock_responses)
    def clear_requests, do: Process.delete(:bluesky_mock_requests)

    def requests do
      Process.get(:bluesky_mock_requests, [])
      |> Enum.reverse()
    end

    def request(method, url, headers, body, opts) do
      request = %{method: method, url: url, headers: headers, body: body, opts: opts}
      Process.put(:bluesky_mock_requests, [request | Process.get(:bluesky_mock_requests, [])])

      case Process.get(:bluesky_mock_responses, []) do
        [next | rest] ->
          Process.put(:bluesky_mock_responses, rest)
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

  test "skips when bridge is disabled" do
    Application.put_env(:elektrine, :bluesky,
      enabled: false,
      service_url: "https://bsky.social",
      timeout_ms: 5_000,
      max_chars: 300,
      http_client: MockHTTPClient
    )

    message = post_fixture(%{visibility: "public"})

    assert {:skipped, :bridge_disabled} = Bluesky.mirror_post(message)
    assert MockHTTPClient.requests() == []
  end

  test "mirrors public post and stores Bluesky uri/cid + user did" do
    user = bluesky_user_fixture()
    message = post_fixture(%{user: user, visibility: "public", content: "hello bluesky"})

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "uri" => "at://did:plc:testdid/app.bsky.feed.post/abc123",
             "cid" => "bafycid123"
           })
       }}
    ])

    assert :ok = Bluesky.mirror_post(message)

    reloaded_message = Repo.get!(Message, message.id)
    assert reloaded_message.bluesky_uri == "at://did:plc:testdid/app.bsky.feed.post/abc123"
    assert reloaded_message.bluesky_cid == "bafycid123"

    reloaded_user = Repo.get!(User, user.id)
    assert reloaded_user.bluesky_did == "did:plc:testdid"

    requests = MockHTTPClient.requests()
    assert Enum.count(requests) == 2
    assert Enum.at(requests, 0).url =~ "/xrpc/com.atproto.server.createSession"
    assert Enum.at(requests, 1).url =~ "/xrpc/com.atproto.repo.createRecord"

    record_payload =
      Enum.at(requests, 1).body
      |> Jason.decode!()
      |> Map.fetch!("record")

    refute Map.has_key?(record_payload, "reply")
    assert record_payload["text"] == "hello bluesky"
  end

  test "skips replies when parent is not mirrored yet" do
    user = bluesky_user_fixture()
    parent = post_fixture(%{user: user, visibility: "public", content: "parent"})
    reply = reply_fixture(user, parent, "child")

    assert {:skipped, :reply_parent_not_mirrored} = Bluesky.mirror_post(reply)
    assert MockHTTPClient.requests() == []
  end

  test "includes root and parent references when mirroring a reply" do
    user = bluesky_user_fixture()
    parent = post_fixture(%{user: user, visibility: "public", content: "parent"})

    from(m in Message, where: m.id == ^parent.id)
    |> Repo.update_all(
      set: [bluesky_uri: "at://did:plc:testdid/app.bsky.feed.post/root", bluesky_cid: "rootcid"]
    )

    reply = reply_fixture(user, parent, "child")

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "uri" => "at://did:plc:testdid/app.bsky.feed.post/reply",
             "cid" => "replycid"
           })
       }}
    ])

    assert :ok = Bluesky.mirror_post(reply)

    record_payload =
      MockHTTPClient.requests()
      |> Enum.at(1)
      |> Map.fetch!(:body)
      |> Jason.decode!()
      |> Map.fetch!("record")

    assert record_payload["reply"]["parent"]["uri"] ==
             "at://did:plc:testdid/app.bsky.feed.post/root"

    assert record_payload["reply"]["parent"]["cid"] == "rootcid"

    assert record_payload["reply"]["root"]["uri"] ==
             "at://did:plc:testdid/app.bsky.feed.post/root"

    assert record_payload["reply"]["root"]["cid"] == "rootcid"
  end

  test "uploads image attachments and includes embed payload" do
    user = bluesky_user_fixture()
    first_key = unique_media_key(".jpg")
    second_key = unique_media_key(".png")

    first_path = create_local_upload(first_key, <<0xFF, 0xD8, 0xFF, 0x00, 0x01>>)
    second_path = create_local_upload(second_key, <<0x89, 0x50, 0x4E, 0x47, 0x00, 0x01>>)

    on_exit(fn ->
      File.rm(first_path)
      File.rm(second_path)
    end)

    message =
      media_post_fixture(%{
        user: user,
        content: "post with media",
        media_urls: [first_key, second_key]
      })
      |> Map.put(:media_metadata, %{"alt_texts" => %{"0" => "First alt", "1" => "Second alt"}})

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "blob" => %{
               "$type" => "blob",
               "ref" => %{"$link" => "bafkqaaa-first"},
               "mimeType" => "image/jpeg",
               "size" => 5
             }
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "blob" => %{
               "$type" => "blob",
               "ref" => %{"$link" => "bafkqaaa-second"},
               "mimeType" => "image/png",
               "size" => 6
             }
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "uri" => "at://did:plc:testdid/app.bsky.feed.post/media1",
             "cid" => "bafycid-media1"
           })
       }}
    ])

    assert :ok = Bluesky.mirror_post(message)

    requests = MockHTTPClient.requests()
    assert Enum.count(requests) == 4
    assert Enum.at(requests, 0).url =~ "/xrpc/com.atproto.server.createSession"
    assert Enum.at(requests, 1).url =~ "/xrpc/com.atproto.repo.uploadBlob"
    assert Enum.at(requests, 2).url =~ "/xrpc/com.atproto.repo.uploadBlob"
    assert Enum.at(requests, 3).url =~ "/xrpc/com.atproto.repo.createRecord"

    assert header_value(Enum.at(requests, 1).headers, "content-type") == "image/jpeg"
    assert header_value(Enum.at(requests, 2).headers, "content-type") == "image/png"

    record_payload =
      Enum.at(requests, 3).body
      |> Jason.decode!()
      |> Map.fetch!("record")

    assert record_payload["text"] == "post with media"
    assert record_payload["embed"]["$type"] == "app.bsky.embed.images"

    assert record_payload["embed"]["images"] == [
             %{
               "image" => %{
                 "$type" => "blob",
                 "mimeType" => "image/jpeg",
                 "ref" => %{"$link" => "bafkqaaa-first"},
                 "size" => 5
               },
               "alt" => "First alt"
             },
             %{
               "image" => %{
                 "$type" => "blob",
                 "mimeType" => "image/png",
                 "ref" => %{"$link" => "bafkqaaa-second"},
                 "size" => 6
               },
               "alt" => "Second alt"
             }
           ]
  end

  test "mirrors media-only posts with empty text" do
    user = bluesky_user_fixture()
    media_key = unique_media_key(".jpg")
    media_path = create_local_upload(media_key, <<0xFF, 0xD8, 0xFF, 0x01>>)

    on_exit(fn ->
      File.rm(media_path)
    end)

    message =
      media_post_fixture(%{
        user: user,
        content: "",
        media_urls: [media_key]
      })

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "blob" => %{
               "$type" => "blob",
               "ref" => %{"$link" => "bafkqaaa-media-only"},
               "mimeType" => "image/jpeg",
               "size" => 4
             }
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "uri" => "at://did:plc:testdid/app.bsky.feed.post/media-only",
             "cid" => "bafycid-media-only"
           })
       }}
    ])

    assert :ok = Bluesky.mirror_post(message)

    record_payload =
      MockHTTPClient.requests()
      |> Enum.at(2)
      |> Map.fetch!(:body)
      |> Jason.decode!()
      |> Map.fetch!("record")

    assert record_payload["text"] == ""
    assert record_payload["embed"]["$type"] == "app.bsky.embed.images"
    assert length(record_payload["embed"]["images"]) == 1
  end

  test "builds rich text facets and quote/link embed mapping" do
    user = bluesky_user_fixture()
    mentioned = bluesky_user_fixture()

    from(u in User, where: u.id == ^mentioned.id)
    |> Repo.update_all(set: [bluesky_did: "did:plc:mentioned"])

    mentioned = Repo.get!(User, mentioned.id)

    quoted = post_fixture(%{user: user, visibility: "public", content: "quoted source"})

    from(m in Message, where: m.id == ^quoted.id)
    |> Repo.update_all(
      set: [
        bluesky_uri: "at://did:plc:testdid/app.bsky.feed.post/quoted1",
        bluesky_cid: "quotedcid1"
      ]
    )

    message =
      post_fixture(%{
        user: user,
        visibility: "public",
        content: "hi @#{mentioned.handle} https://example.com #tag"
      })

    from(m in Message, where: m.id == ^message.id)
    |> Repo.update_all(
      set: [quoted_message_id: quoted.id, primary_url: "https://example.org/article"]
    )

    message = Repo.get!(Message, message.id)

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "uri" => "at://did:plc:testdid/app.bsky.feed.post/facets1",
             "cid" => "bafycid-facets1"
           })
       }}
    ])

    assert :ok = Bluesky.mirror_post(message)

    record_payload =
      MockHTTPClient.requests()
      |> Enum.at(1)
      |> Map.fetch!(:body)
      |> Jason.decode!()
      |> Map.fetch!("record")

    features =
      record_payload["facets"]
      |> Enum.flat_map(&(&1["features"] || []))

    assert Enum.any?(features, &(&1["$type"] == "app.bsky.richtext.facet#link"))

    assert Enum.any?(
             features,
             &(&1["$type"] == "app.bsky.richtext.facet#tag" and &1["tag"] == "tag")
           )

    assert Enum.any?(features, fn feature ->
             feature["$type"] == "app.bsky.richtext.facet#mention" and
               feature["did"] == "did:plc:mentioned"
           end)

    assert record_payload["embed"]["$type"] == "app.bsky.embed.recordWithMedia"
    assert record_payload["embed"]["record"]["$type"] == "app.bsky.embed.record"

    assert record_payload["embed"]["record"]["record"]["uri"] ==
             "at://did:plc:testdid/app.bsky.feed.post/quoted1"

    assert record_payload["embed"]["media"]["$type"] == "app.bsky.embed.external"
    assert record_payload["embed"]["media"]["external"]["uri"] == "https://example.org/article"
  end

  test "maps video attachments to Bluesky video embed" do
    user = bluesky_user_fixture()
    video_key = unique_media_key(".mp4")

    video_path =
      create_local_upload(video_key, <<0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70>>)

    on_exit(fn ->
      File.rm(video_path)
    end)

    message =
      media_post_fixture(%{
        user: user,
        content: "video post",
        media_urls: [video_key]
      })
      |> Map.put(:media_metadata, %{"alt_texts" => %{"0" => "Video alt"}})

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "blob" => %{
               "$type" => "blob",
               "ref" => %{"$link" => "bafkqaaa-video"},
               "mimeType" => "video/mp4",
               "size" => 8
             }
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "uri" => "at://did:plc:testdid/app.bsky.feed.post/video1",
             "cid" => "bafycid-video1"
           })
       }}
    ])

    assert :ok = Bluesky.mirror_post(message)

    requests = MockHTTPClient.requests()
    assert Enum.at(requests, 1).url =~ "/xrpc/com.atproto.repo.uploadBlob"
    assert header_value(Enum.at(requests, 1).headers, "content-type") == "video/mp4"

    record_payload =
      Enum.at(requests, 2).body
      |> Jason.decode!()
      |> Map.fetch!("record")

    assert record_payload["embed"]["$type"] == "app.bsky.embed.video"
    assert record_payload["embed"]["video"]["mimeType"] == "video/mp4"
  end

  test "maps non-image media to external embeds" do
    user = bluesky_user_fixture()
    audio_key = unique_media_key(".mp3")
    audio_path = create_local_upload(audio_key, <<0x49, 0x44, 0x33, 0x03, 0x00, 0x00>>)

    on_exit(fn ->
      File.rm(audio_path)
    end)

    message =
      media_post_fixture(%{
        user: user,
        content: "",
        media_urls: [audio_key]
      })

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "uri" => "at://did:plc:testdid/app.bsky.feed.post/audio1",
             "cid" => "bafycid-audio1"
           })
       }}
    ])

    assert :ok = Bluesky.mirror_post(message)

    requests = MockHTTPClient.requests()
    assert Enum.count(requests) == 2

    record_payload =
      Enum.at(requests, 1).body
      |> Jason.decode!()
      |> Map.fetch!("record")

    assert record_payload["embed"]["$type"] == "app.bsky.embed.external"
    assert record_payload["embed"]["external"]["uri"] =~ "/uploads/"
  end

  test "mirrors likes and unlikes to Bluesky records" do
    user = bluesky_user_fixture()
    message = post_fixture(%{user: user, visibility: "public", content: "like target"})

    from(m in Message, where: m.id == ^message.id)
    |> Repo.update_all(
      set: [
        bluesky_uri: "at://did:plc:testdid/app.bsky.feed.post/liked1",
        bluesky_cid: "likedcid1"
      ]
    )

    message = Repo.get!(Message, message.id)

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok, %Finch.Response{status: 200, body: Jason.encode!(%{"records" => []})}},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "uri" => "at://did:plc:testdid/app.bsky.feed.like/like1",
             "cid" => "likecid1"
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "records" => [
               %{
                 "uri" => "at://did:plc:testdid/app.bsky.feed.like/like1",
                 "value" => %{"subject" => %{"uri" => message.bluesky_uri}}
               }
             ]
           })
       }},
      {:ok, %Finch.Response{status: 200, body: "{}"}}
    ])

    assert :ok = Bluesky.mirror_like(message.id, user.id)
    assert :ok = Bluesky.mirror_unlike(message.id, user.id)

    requests = MockHTTPClient.requests()
    assert Enum.at(requests, 2).url =~ "/xrpc/com.atproto.repo.createRecord"
    assert Enum.at(requests, 5).url =~ "/xrpc/com.atproto.repo.deleteRecord"

    like_payload =
      Enum.at(requests, 2).body
      |> Jason.decode!()

    assert like_payload["collection"] == "app.bsky.feed.like"
    assert like_payload["record"]["subject"]["uri"] == message.bluesky_uri
  end

  test "mirrors reposts and follows (plus undo)" do
    user = bluesky_user_fixture()
    followed = bluesky_user_fixture()

    from(u in User, where: u.id == ^followed.id)
    |> Repo.update_all(set: [bluesky_did: "did:plc:followed"])

    followed = Repo.get!(User, followed.id)
    message = post_fixture(%{user: user, visibility: "public", content: "repost target"})

    from(m in Message, where: m.id == ^message.id)
    |> Repo.update_all(
      set: [
        bluesky_uri: "at://did:plc:testdid/app.bsky.feed.post/repost1",
        bluesky_cid: "repostcid1"
      ]
    )

    message = Repo.get!(Message, message.id)

    MockHTTPClient.put_responses([
      # repost
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok, %Finch.Response{status: 200, body: Jason.encode!(%{"records" => []})}},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "uri" => "at://did:plc:testdid/app.bsky.feed.repost/repost1",
             "cid" => "repostcid1"
           })
       }},
      # unrepost
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "records" => [
               %{
                 "uri" => "at://did:plc:testdid/app.bsky.feed.repost/repost1",
                 "value" => %{"subject" => %{"uri" => message.bluesky_uri}}
               }
             ]
           })
       }},
      {:ok, %Finch.Response{status: 200, body: "{}"}},
      # follow
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok, %Finch.Response{status: 200, body: Jason.encode!(%{"records" => []})}},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "uri" => "at://did:plc:testdid/app.bsky.graph.follow/follow1",
             "cid" => "followcid1"
           })
       }},
      # unfollow
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "records" => [
               %{
                 "uri" => "at://did:plc:testdid/app.bsky.graph.follow/follow1",
                 "value" => %{"subject" => followed.bluesky_did}
               }
             ]
           })
       }},
      {:ok, %Finch.Response{status: 200, body: "{}"}}
    ])

    assert :ok = Bluesky.mirror_repost(message.id, user.id)
    assert :ok = Bluesky.mirror_unrepost(message.id, user.id)
    assert :ok = Bluesky.mirror_follow(user.id, followed.id)
    assert :ok = Bluesky.mirror_unfollow(user.id, followed.id)

    requests = MockHTTPClient.requests()

    repost_payload =
      Enum.at(requests, 2).body
      |> Jason.decode!()

    assert repost_payload["collection"] == "app.bsky.feed.repost"
    assert repost_payload["record"]["subject"]["uri"] == message.bluesky_uri

    follow_payload =
      Enum.at(requests, 8).body
      |> Jason.decode!()

    assert follow_payload["collection"] == "app.bsky.graph.follow"
    assert follow_payload["record"]["subject"] == followed.bluesky_did
  end

  test "updates and deletes already mirrored posts" do
    user = bluesky_user_fixture()
    message = post_fixture(%{user: user, visibility: "public", content: "before"})

    from(m in Message, where: m.id == ^message.id)
    |> Repo.update_all(
      set: [
        bluesky_uri: "at://did:plc:testdid/app.bsky.feed.post/edit1",
        bluesky_cid: "oldcid1",
        content: "after edit"
      ]
    )

    message = Repo.get!(Message, message.id)

    MockHTTPClient.put_responses([
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "uri" => "at://did:plc:testdid/app.bsky.feed.post/edit1",
             "cid" => "newcid1"
           })
       }},
      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"accessJwt" => "jwt_token", "did" => "did:plc:testdid"})
       }},
      {:ok, %Finch.Response{status: 200, body: "{}"}}
    ])

    assert :ok = Bluesky.mirror_post_update(message)
    assert :ok = Bluesky.mirror_post_delete(message)

    requests = MockHTTPClient.requests()
    assert Enum.at(requests, 1).url =~ "/xrpc/com.atproto.repo.putRecord"
    assert Enum.at(requests, 3).url =~ "/xrpc/com.atproto.repo.deleteRecord"

    put_payload =
      Enum.at(requests, 1).body
      |> Jason.decode!()

    assert put_payload["collection"] == "app.bsky.feed.post"
    assert put_payload["rkey"] == "edit1"
    assert put_payload["record"]["text"] == "after edit"

    reloaded = Repo.get!(Message, message.id)
    assert reloaded.bluesky_cid == "newcid1"
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

  defp reply_fixture(user, parent, content) do
    {:ok, reply} =
      %Message{}
      |> Message.changeset(%{
        conversation_id: parent.conversation_id,
        sender_id: user.id,
        content: content,
        message_type: "text",
        visibility: "public",
        post_type: "post",
        reply_to_id: parent.id
      })
      |> Repo.insert()

    reply
  end

  defp unique_media_key(ext) do
    "timeline-attachments/bluesky-test-#{System.unique_integer([:positive])}#{ext}"
  end

  defp create_local_upload(relative_key, content) do
    uploads_dir =
      Application.get_env(:elektrine, :uploads, [])
      |> Keyword.get(:uploads_dir, "tmp/test_uploads")

    path = Path.join(uploads_dir, relative_key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp header_value(headers, key) do
    headers
    |> Enum.find_value(fn
      {header_key, value} when is_binary(header_key) and is_binary(value) ->
        if String.downcase(header_key) == String.downcase(key), do: value, else: nil

      _ ->
        nil
    end)
  end
end
