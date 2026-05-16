defmodule ElektrineEmailWeb.EmailLive.EmailHelpersAttachmentTest do
  use ExUnit.Case, async: true

  alias ElektrineEmailWeb.EmailLive.EmailHelpers

  test "visible attachments exclude inline cid images" do
    message = %{
      attachments: %{
        "attachment_0" => %{
          "filename" => "logo.png",
          "content_type" => "image/png",
          "content_id" => "<logo@example.com>",
          "disposition" => "inline"
        },
        "attachment_1" => %{
          "filename" => "report.pdf",
          "content_type" => "application/pdf",
          "disposition" => "attachment"
        }
      }
    }

    assert EmailHelpers.visible_attachments(message) == %{
             "attachment_1" => %{
               "filename" => "report.pdf",
               "content_type" => "application/pdf",
               "disposition" => "attachment"
             }
           }

    assert EmailHelpers.visible_attachment_count(message) == 1
  end
end
