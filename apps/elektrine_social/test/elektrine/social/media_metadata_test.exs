defmodule Elektrine.Social.MediaMetadataTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.Social
  alias Elektrine.Social.Drafts

  test "merge_post_media_metadata normalizes local upload attachments and applies alt text" do
    metadata =
      Social.merge_post_media_metadata(
        %{
          "attachments" => [
            %{
              key: "timeline-attachments/test-image.png",
              content_type: "image/png",
              size: 12_345,
              width: 640,
              height: 480
            }
          ]
        },
        %{"0" => "Stable preview"}
      )

    assert metadata["alt_texts"] == %{"0" => "Stable preview"}

    assert [
             %{
               "alt_text" => "Stable preview",
               "authorization" => "public",
               "byte_size" => 12_345,
               "height" => 480,
               "mime_type" => "image/png",
               "retention" => "origin",
               "url" => "timeline-attachments/test-image.png",
               "width" => 640
             } = attachment
           ] = metadata["attachments"]

    assert is_binary(attachment["id"])
  end

  test "create_timeline_post and drafts preserve normalized attachment metadata" do
    user = AccountsFixtures.user_fixture()

    media_metadata = %{
      "attachments" => [
        %{
          key: "timeline-attachments/test-image.png",
          content_type: "image/png",
          size: 12_345,
          width: 640,
          height: 480
        }
      ]
    }

    {:ok, post} =
      Social.create_timeline_post(user.id, "Media metadata path",
        visibility: "public",
        media_urls: ["timeline-attachments/test-image.png"],
        media_metadata: media_metadata,
        alt_texts: %{"0" => "Uploaded alt"}
      )

    assert [
             %{
               "alt_text" => "Uploaded alt",
               "byte_size" => 12_345,
               "height" => 480,
               "mime_type" => "image/png",
               "url" => "timeline-attachments/test-image.png",
               "width" => 640
             }
           ] = post.media_metadata["attachments"]

    {:ok, draft} =
      Drafts.save_draft(user.id,
        content: "Draft metadata path",
        media_urls: ["timeline-attachments/test-image.png"],
        media_metadata: media_metadata,
        alt_texts: %{"0" => "Draft alt"}
      )

    assert [
             %{
               "alt_text" => "Draft alt",
               "height" => 480,
               "mime_type" => "image/png",
               "url" => "timeline-attachments/test-image.png",
               "width" => 640
             }
           ] = draft.media_metadata["attachments"]

    {:ok, updated_draft} =
      Drafts.save_draft(user.id,
        draft_id: draft.id,
        media_urls: ["timeline-attachments/test-image.png"],
        media_metadata: draft.media_metadata,
        alt_texts: %{"0" => "Updated draft alt"}
      )

    assert [
             %{
               "alt_text" => "Updated draft alt",
               "height" => 480,
               "mime_type" => "image/png",
               "url" => "timeline-attachments/test-image.png",
               "width" => 640
             }
           ] = updated_draft.media_metadata["attachments"]
  end
end
