defmodule Elektrine.Email.MimeBodyExtractorTest do
  use ExUnit.Case, async: true

  alias Elektrine.Email.MimeBodyExtractor

  test "extracts nested Thunderbird-style alternative bodies case-insensitively" do
    message = %Mail.Message{
      multipart: true,
      headers: %{"content-type" => ["multipart/mixed"]},
      parts: [
        %Mail.Message{
          multipart: true,
          headers: %{"content-type" => ["multipart/alternative"]},
          parts: [
            %Mail.Message{
              headers: %{"content-type" => ["Text/Plain", {"charset", "UTF-8"}]},
              body: "hello from thunderbird"
            },
            %Mail.Message{
              headers: %{"content-type" => ["Text/HTML", {"charset", "UTF-8"}]},
              body: "<p>hello from thunderbird</p>"
            }
          ]
        }
      ]
    }

    assert MimeBodyExtractor.text_body(message) == "hello from thunderbird"
    assert MimeBodyExtractor.html_body(message) == "<p>hello from thunderbird</p>"
  end

  test "ignores attachment text parts when selecting a display body" do
    message = %Mail.Message{
      multipart: true,
      headers: %{"content-type" => ["multipart/mixed"]},
      parts: [
        %Mail.Message{headers: %{"content-type" => ["text/plain"]}, body: "visible text"},
        %Mail.Message{
          headers: %{"content-type" => ["text/plain"], "content-disposition" => ["attachment"]},
          body: "attached text"
        }
      ]
    }

    assert MimeBodyExtractor.text_body(message) == "visible text"
  end

  test "uses a non-multipart root body as text when content type is missing" do
    message = %Mail.Message{
      headers: %{"x-client" => "Thunderbird"},
      body: "visible root text",
      multipart: false
    }

    assert MimeBodyExtractor.text_body(message) == "visible root text"
  end
end
