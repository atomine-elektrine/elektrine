defmodule Elektrine.ActivityPub.NormalizerTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Normalizer

  describe "message_payload/3" do
    test "normalizes Mastodon-style notes into message attrs" do
      actor_uri = "https://remote.example/users/alice"
      local_actor_href = "#{ActivityPub.instance_url()}/users/maxfield"
      published = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      object = %{
        "type" => "Note",
        "id" => "https://remote.example/users/alice/statuses/1",
        "url" => "https://remote.example/@alice/1",
        "attributedTo" => actor_uri,
        "content" =>
          ~s(<p>Hello <a href="#{local_actor_href}" class="u-url mention">@<span>maxfield</span></a> #Elixir</p>),
        "summary" => "spoiler",
        "sensitive" => true,
        "indexable" => false,
        "published" => published,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "likes" => %{"totalItems" => "7"},
        "replies" => %{"totalItems" => 3},
        "shares" => 2,
        "attachment" => [
          %{
            "type" => "Document",
            "mediaType" => "image/jpeg",
            "url" => "https://remote.example/media/photo.jpg",
            "name" => "A cat"
          }
        ],
        "tag" => [
          %{
            "type" => "Mention",
            "href" => local_actor_href,
            "name" => "@maxfield"
          },
          %{"type" => "Hashtag", "name" => "#Phoenix"}
        ]
      }

      payload = Normalizer.message_payload(object, actor_uri)

      assert payload.attrs.content == "Hello @maxfield@#{ActivityPub.instance_domain()} #Elixir"
      assert payload.attrs.visibility == "public"
      assert payload.attrs.activitypub_id == object["id"]
      assert payload.attrs.activitypub_url == object["url"]
      assert payload.attrs.like_count == 7
      assert payload.attrs.reply_count == 3
      assert payload.attrs.share_count == 2
      assert payload.attrs.sensitive == true
      assert payload.attrs.content_warning == "spoiler"
      assert payload.attrs.media_metadata["indexable"] == false
      assert payload.attrs.media_urls == ["https://remote.example/media/photo.jpg"]
      assert get_in(payload.attrs.media_metadata, ["alt_texts", "0"]) == "A cat"
      assert payload.hashtags == ["phoenix", "elixir"]
      assert payload.mentioned_local_users == ["maxfield"]
    end

    test "normalizes Lemmy-style link and community metadata" do
      actor_uri = "https://lemmy.example/u/alice"

      object = %{
        "type" => "Page",
        "id" => "https://lemmy.example/post/123",
        "attributedTo" => actor_uri,
        "name" => "<h1>Useful Elixir link</h1>",
        "content" => "<p>#ActivityPub discussion</p>",
        "published" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "audience" => "https://lemmy.example/c/elixir",
        "upvotes" => 12,
        "downvotes" => 2,
        "score" => 10,
        "attachment" => [
          %{
            "type" => "Link",
            "href" => "https://example.com/elixir"
          }
        ]
      }

      payload = Normalizer.message_payload(object, actor_uri)

      assert payload.attrs.title == "Useful Elixir link"
      assert payload.attrs.primary_url == "https://example.com/elixir"
      assert payload.attrs.upvotes == 12
      assert payload.attrs.downvotes == 2
      assert payload.attrs.score == 10
      assert payload.attrs.media_metadata["external_link"] == "https://example.com/elixir"

      assert payload.attrs.media_metadata["community_actor_uri"] ==
               "https://lemmy.example/c/elixir"

      assert payload.hashtags == ["activitypub"]
    end

    test "drops unsafe submitted links from ActivityPub metadata" do
      actor_uri = "https://lemmy.example/u/alice"

      object = %{
        "type" => "Page",
        "id" => "https://lemmy.example/post/unsafe",
        "attributedTo" => actor_uri,
        "name" => "Unsafe link",
        "content" => "unsafe",
        "published" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "attachment" => [
          %{
            "type" => "Link",
            "href" => "javascript:alert(1)"
          }
        ]
      }

      payload = Normalizer.message_payload(object, actor_uri)

      refute Map.has_key?(payload.attrs.media_metadata, "external_link")
    end
  end

  describe "question_payload/3" do
    test "normalizes Question polls into poll payloads" do
      actor_uri = "https://remote.example/users/pollster"

      object = %{
        "type" => "Question",
        "id" => "https://remote.example/questions/1",
        "attributedTo" => actor_uri,
        "name" => "<p>Pick one #Polls</p>",
        "content" => "",
        "published" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "oneOf" => [
          %{"name" => "One", "replies" => %{"totalItems" => "4"}},
          %{"name" => "Two", "replies" => %{"totalItems" => 2}}
        ],
        "votersCount" => "6"
      }

      payload = Normalizer.question_payload(object, actor_uri)

      assert payload.attrs.post_type == "poll"
      assert payload.question == "Pick one #Polls"
      assert payload.hashtags == ["polls"]

      assert payload.options == [
               %{text: "One", votes: 4, position: 0},
               %{text: "Two", votes: 2, position: 1}
             ]
    end
  end

  describe "actor reference normalization" do
    test "extracts actor URIs from PeerTube attributedTo lists" do
      account_uri = "https://tilvids.com/accounts/thelinuxexperiment"
      channel_uri = "https://tilvids.com/video-channels/thelinuxexperiment_channel"

      object = %{
        "attributedTo" => [
          %{"id" => account_uri, "type" => "Person"},
          %{"id" => channel_uri, "type" => "Group"}
        ]
      }

      assert Normalizer.actor_uri(object) == account_uri
      assert Normalizer.actor_ref_uri(object["attributedTo"]) == account_uri
    end

    test "validates signed actors contained in attributedTo lists" do
      account_uri = "https://tilvids.com/accounts/thelinuxexperiment"
      channel_uri = "https://tilvids.com/video-channels/thelinuxexperiment_channel"

      object = %{
        "attributedTo" => [
          %{"id" => account_uri, "type" => "Person"},
          %{"id" => channel_uri, "type" => "Group"}
        ]
      }

      assert :ok = Normalizer.validate_object_author(object, channel_uri)
    end
  end

  describe "platform fixture normalization" do
    test "normalizes Misskey reactions and quote metadata" do
      actor_uri = "https://misskey.example/users/alice"

      object =
        note_fixture(actor_uri, %{
          "id" => "https://misskey.example/notes/abc123",
          "content" => "<p>Misskey note</p>",
          "reactionCount" => 5,
          "reactions" => %{"thumbs_up" => 3, ":blobcat:" => "2", ":zero:" => 0},
          "renoteCount" => 4,
          "repliesCount" => 6,
          "renoteId" => "renote-1",
          "_misskey_quote" => "https://misskey.example/notes/quoted"
        })

      payload = Normalizer.message_payload(object, actor_uri)

      assert payload.attrs.reply_count == 6
      assert payload.attrs.media_metadata["quote_url"] == "https://misskey.example/notes/quoted"
      assert payload.attrs.media_metadata["quote_id"] == "renote-1"
      assert payload.attrs.media_metadata["misskey"]["reactionCount"] == 5

      assert Enum.sort_by(payload.attrs.media_metadata["emoji_reactions"], & &1["name"]) == [
               %{"name" => ":blobcat:", "count" => 2},
               %{"name" => "thumbs_up", "count" => 3}
             ]
    end

    test "normalizes Pleroma/Akkoma counts and metadata" do
      actor_uri = "https://akkoma.example/users/alice"

      object =
        note_fixture(actor_uri, %{
          "id" => "https://akkoma.example/objects/1",
          "content" => "<p>Pleroma note</p>",
          "like_count" => "9",
          "announcement_count" => 4,
          "pleroma" => %{
            "emoji_reactions" => [%{"name" => "heart", "count" => 2}],
            "quotes_count" => "3",
            "quote_url" => "https://akkoma.example/objects/quoted"
          }
        })

      payload = Normalizer.message_payload(object, actor_uri)

      assert payload.attrs.like_count == 9
      assert payload.attrs.share_count == 4
      assert payload.attrs.quote_count == 3

      assert payload.attrs.media_metadata["emoji_reactions"] == [
               %{"name" => "heart", "count" => 2}
             ]

      assert payload.attrs.media_metadata["quote_url"] == "https://akkoma.example/objects/quoted"
    end

    test "normalizes Pixelfed media attachments" do
      actor_uri = "https://pixelfed.example/users/alice"

      object =
        note_fixture(actor_uri, %{
          "id" => "https://pixelfed.example/p/alice/1",
          "content" => "<p>Photo post #Photography</p>",
          "attachment" => %{
            "type" => "Document",
            "mediaType" => "image/jpeg",
            "url" => "https://pixelfed.example/storage/m/photo.jpg",
            "name" => "A skyline"
          }
        })

      payload = Normalizer.message_payload(object, actor_uri)

      assert payload.attrs.media_urls == ["https://pixelfed.example/storage/m/photo.jpg"]

      assert get_in(payload.attrs.media_metadata, ["media_attachments", Access.at(0), "type"]) ==
               "image"

      assert get_in(payload.attrs.media_metadata, ["alt_texts", "0"]) == "A skyline"
      assert payload.hashtags == ["photography"]
    end

    test "normalizes PeerTube video attachments" do
      actor_uri = "https://peertube.example/accounts/alice"

      object =
        note_fixture(actor_uri, %{
          "type" => "Video",
          "id" => "https://peertube.example/videos/watch/1",
          "name" => "<p>Federation talk</p>",
          "content" => "<p>PeerTube video</p>",
          "attachment" => [
            %{
              "type" => "Document",
              "mediaType" => "video/mp4",
              "url" => "https://peertube.example/static/webseed/video.mp4",
              "name" => "Video file"
            }
          ],
          "language" => "en"
        })

      payload = Normalizer.message_payload(object, actor_uri)

      assert payload.attrs.title == "Federation talk"
      assert payload.attrs.media_urls == ["https://peertube.example/static/webseed/video.mp4"]

      assert get_in(payload.attrs.media_metadata, ["media_attachments", Access.at(0), "type"]) ==
               "video"

      assert payload.attrs.media_metadata["language"] == "en"
    end

    test "normalizes PeerTube video links from url arrays" do
      actor_uri = "https://peertube.example/accounts/alice"

      object =
        note_fixture(actor_uri, %{
          "type" => "Video",
          "id" => "https://peertube.example/videos/watch/2",
          "name" => "Federation talk",
          "content" => "<p>PeerTube video</p>",
          "duration" => "PT10M",
          "icon" => %{
            "type" => "Image",
            "mediaType" => "image/jpeg",
            "url" => "https://peertube.example/lazy-static/previews/video.jpg"
          },
          "url" => [
            %{
              "type" => "Link",
              "mediaType" => "text/html",
              "href" => "https://peertube.example/w/federation-talk"
            },
            %{
              "type" => "Link",
              "mediaType" => "video/mp4",
              "href" => "https://peertube.example/download/stream",
              "width" => 1920,
              "height" => 1080
            }
          ]
        })

      payload = Normalizer.message_payload(object, actor_uri)

      assert payload.attrs.media_urls == ["https://peertube.example/download/stream"]
      assert payload.attrs.media_metadata["type"] == "Video"
      assert payload.attrs.media_metadata["duration"] == "PT10M"

      assert payload.attrs.media_metadata["thumbnail_url"] ==
               "https://peertube.example/lazy-static/previews/video.jpg"

      attachment = get_in(payload.attrs.media_metadata, ["media_attachments", Access.at(0)])
      assert attachment["type"] == "video"
      assert attachment["mediaType"] == "video/mp4"

      assert attachment["preview_url"] ==
               "https://peertube.example/lazy-static/previews/video.jpg"

      assert attachment["width"] == 1920
      assert attachment["height"] == 1080
    end

    test "normalizes GoToSocial style counters" do
      actor_uri = "https://gotosocial.example/users/alice"

      object =
        note_fixture(actor_uri, %{
          "id" => "https://gotosocial.example/users/alice/statuses/1",
          "content" => "<p>GoToSocial note</p>",
          "favourites_count" => "11",
          "reblogs_count" => "5",
          "replies_count" => 7,
          "url" => "https://gotosocial.example/@alice/statuses/1"
        })

      payload = Normalizer.message_payload(object, actor_uri)

      assert payload.attrs.like_count == 11
      assert payload.attrs.share_count == 5
      assert payload.attrs.reply_count == 7
      assert payload.attrs.activitypub_url == "https://gotosocial.example/@alice/statuses/1"
    end
  end

  defp note_fixture(actor_uri, overrides) do
    Map.merge(
      %{
        "type" => "Note",
        "id" => "https://remote.example/objects/#{System.unique_integer([:positive])}",
        "attributedTo" => actor_uri,
        "content" => "<p>Hello</p>",
        "published" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      },
      overrides
    )
  end
end
