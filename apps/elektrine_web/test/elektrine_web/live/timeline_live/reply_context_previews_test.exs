defmodule ElektrineSocialWeb.TimelineLive.ReplyContextPreviewsTest do
  use Elektrine.DataCase, async: true

  alias ElektrineSocialWeb.TimelineLive.ReplyContextPreviews

  test "candidate_refs returns only replies missing preview content" do
    posts = [
      %{id: 1, media_metadata: %{"inReplyTo" => "https://outerheaven.club/notes/1"}},
      %{
        id: 2,
        media_metadata: %{
          "inReplyTo" => "https://outerheaven.club/notes/1",
          "inReplyToContent" => "<p>Already loaded</p>"
        }
      },
      %{
        id: 3,
        media_metadata: %{"inReplyTo" => "https://outerheaven.club/notes/2"},
        reply_to: %{content: "Local parent content"}
      },
      %{id: 4, media_metadata: %{}}
    ]

    assert ReplyContextPreviews.candidate_refs(posts) == ["https://outerheaven.club/notes/1"]
  end

  test "fetch_previews extracts ancestor content and author from fetched objects" do
    ref = "https://outerheaven.club/notes/42"

    previews =
      ReplyContextPreviews.fetch_previews([ref], fn ^ref ->
        {:ok,
         %{
           "content" => "<p>Parent body</p>",
           "attributedTo" => "https://outerheaven.club/users/sludgecatheter"
         }}
      end)

    assert previews == %{
             ref => %{
               "inReplyToAuthor" => "@sludgecatheter@outerheaven.club",
               "inReplyToContent" => "<p>Parent body</p>"
             }
           }
  end

  test "apply_previews fills missing metadata without overwriting existing previews" do
    posts = [
      %{id: 1, media_metadata: %{"inReplyTo" => "https://outerheaven.club/notes/1"}},
      %{
        id: 2,
        media_metadata: %{
          "inReplyTo" => "https://outerheaven.club/notes/2",
          "inReplyToContent" => "<p>Keep this</p>"
        }
      }
    ]

    previews = %{
      "https://outerheaven.club/notes/1" => %{
        "inReplyToAuthor" => "@sludgecatheter@outerheaven.club",
        "inReplyToContent" => "<p>Fetched parent</p>"
      },
      "https://outerheaven.club/notes/2" => %{
        "inReplyToContent" => "<p>Do not replace</p>"
      }
    }

    assert [
             %{
               media_metadata: %{
                 "inReplyTo" => "https://outerheaven.club/notes/1",
                 "inReplyToAuthor" => "@sludgecatheter@outerheaven.club",
                 "inReplyToContent" => "<p>Fetched parent</p>"
               }
             },
             %{
               media_metadata: %{
                 "inReplyTo" => "https://outerheaven.club/notes/2",
                 "inReplyToContent" => "<p>Keep this</p>"
               }
             }
           ] = ReplyContextPreviews.apply_previews(posts, previews)
  end
end
