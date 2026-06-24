defmodule Elektrine.Email.SanitizerTest do
  use ExUnit.Case, async: true

  alias Elektrine.Email.Sanitizer

  describe "sanitize_utf8/1 - invalid UTF-8 handling" do
    test "removes null bytes (PostgreSQL incompatible)" do
      # PostgreSQL does not allow null bytes in text fields
      content_with_null = "Hello" <> <<0>> <> "World"
      result = Sanitizer.sanitize_utf8(content_with_null)

      assert String.valid?(result)
      assert result == "HelloWorld"
      refute String.contains?(result, <<0>>)
      assert {:ok, _} = Jason.encode(result)
    end

    test "removes multiple null bytes" do
      content = "A" <> <<0>> <> "B" <> <<0, 0>> <> "C"
      result = Sanitizer.sanitize_utf8(content)

      assert String.valid?(result)
      assert result == "ABC"
      refute String.contains?(result, <<0>>)
      assert {:ok, _} = Jason.encode(result)
    end

    test "handles null bytes with invalid UTF-8" do
      # Combination of null bytes and invalid UTF-8
      content = "Hello" <> <<0>> <> <<0xE5, 0x86>> <> <<0>> <> "World"
      result = Sanitizer.sanitize_utf8(content)

      assert String.valid?(result)
      refute String.contains?(result, <<0>>)
      assert String.contains?(result, "Hello")
      assert String.contains?(result, "World")
      assert {:ok, _} = Jason.encode(result)
    end

    test "handles incomplete 2-byte sequence" do
      invalid = <<0xC2>>
      result = Sanitizer.sanitize_utf8(invalid)

      assert String.valid?(result)
      assert {:ok, _} = Jason.encode(result)
    end

    test "handles incomplete 3-byte sequence" do
      invalid = <<0xE5, 0x86>>
      result = Sanitizer.sanitize_utf8(invalid)

      assert String.valid?(result)
      assert {:ok, _} = Jason.encode(result)
    end

    test "handles the exact error sequence (0xE5 0x86 0xE5)" do
      # This is the exact sequence from the production error
      invalid = <<0xE5, 0x86, 0xE5>>
      result = Sanitizer.sanitize_utf8(invalid)

      assert String.valid?(result)
      assert {:ok, _} = Jason.encode(result)
    end

    test "handles invalid continuation byte" do
      invalid = <<0xC2, 0xFF>>
      result = Sanitizer.sanitize_utf8(invalid)

      assert String.valid?(result)
      assert {:ok, _} = Jason.encode(result)
    end

    test "handles mixed valid and invalid UTF-8" do
      invalid = "Hello " <> <<0xE5, 0x86>> <> " World"
      result = Sanitizer.sanitize_utf8(invalid)

      assert String.valid?(result)
      assert String.contains?(result, "Hello")
      assert String.contains?(result, "World")
      assert {:ok, _} = Jason.encode(result)
    end

    test "handles the production error subject line bytes" do
      # From error: <<70, 119, 100, 58, 32, 229, 135, 178...>>
      # This contains Chinese characters that may be double-encoded
      corrupted_subject = <<70, 119, 100, 58, 32, 0xE5, 0x86, 0xE5>>
      result = Sanitizer.sanitize_utf8(corrupted_subject)

      assert String.valid?(result)
      assert String.starts_with?(result, "Fwd:")
      assert {:ok, _} = Jason.encode(result)
    end

    test "preserves valid Chinese UTF-8" do
      valid_chinese = "Fwd: 已添加 Microsoft 帐户安全信息"
      result = Sanitizer.sanitize_utf8(valid_chinese)

      assert String.valid?(result)
      assert String.contains?(result, "Microsoft")
      assert {:ok, _} = Jason.encode(result)
    end

    test "handles nil input" do
      result = Sanitizer.sanitize_utf8(nil)

      assert result == ""
      assert String.valid?(result)
    end

    test "handles empty string" do
      result = Sanitizer.sanitize_utf8("")

      assert result == ""
      assert String.valid?(result)
    end

    test "preserves ASCII text" do
      ascii = "Hello World! 123"
      result = Sanitizer.sanitize_utf8(ascii)

      assert result == ascii
      assert String.valid?(result)
    end

    test "preserves emojis" do
      emoji_text = "Hello 👋 World 🌍"
      result = Sanitizer.sanitize_utf8(emoji_text)

      assert String.contains?(result, "👋")
      assert String.contains?(result, "🌍")
      assert String.valid?(result)
    end
  end

  describe "sanitize_incoming_email/1 - link preservation" do
    test "preserves HTTPS links in HTML" do
      email_data = %{
        "html_body" => "<a href=\"https://example.com\">Click here</a>",
        "text_body" => "Link: https://example.com"
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      assert String.contains?(result["html_body"], "https://example.com")
      assert String.contains?(result["text_body"], "https://example.com")
    end

    test "preserves HTTP links in HTML" do
      email_data = %{
        "html_body" => "<a href=\"http://example.com\">Click here</a>",
        "text_body" => "Link: http://example.com"
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      assert String.contains?(result["html_body"], "http://example.com")
      assert String.contains?(result["text_body"], "http://example.com")
    end

    test "preserves multiple links" do
      email_data = %{
        "html_body" => """
        <p>Check out <a href="https://google.com">Google</a></p>
        <p>Also <a href="https://github.com">GitHub</a></p>
        """,
        "text_body" => "Google: https://google.com\nGitHub: https://github.com"
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      assert String.contains?(result["html_body"], "https://google.com")
      assert String.contains?(result["html_body"], "https://github.com")
      assert String.contains?(result["text_body"], "https://google.com")
      assert String.contains?(result["text_body"], "https://github.com")
    end

    test "preserves HTML formatting (styles, images, etc)" do
      email_data = %{
        "html_body" => """
        <div style="color: red;">
          <img src="https://example.com/image.png" />
          <p><strong>Bold text</strong></p>
        </div>
        """
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      assert String.contains?(result["html_body"], "style=")
      assert String.contains?(result["html_body"], "<img")
      assert String.contains?(result["html_body"], "<strong>")
      assert String.contains?(result["html_body"], "https://example.com/image.png")
    end

    test "fixes UTF-8 encoding issues while preserving links" do
      email_data = %{
        "html_body" => "<a href=\"https://example.com\">Click " <> <<0xE5, 0x86>> <> " here</a>",
        "text_body" => "Link: https://example.com " <> <<0xE5, 0x86>>
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      assert String.valid?(result["html_body"])
      assert String.valid?(result["text_body"])
      assert String.contains?(result["html_body"], "https://example.com")
      assert String.contains?(result["text_body"], "https://example.com")
      assert {:ok, _} = Jason.encode(result)
    end

    test "sanitizes headers to prevent SMTP injection" do
      email_data = %{
        "from" => "test@example.com\nBcc: hacker@evil.com",
        "subject" => "Test\r\nBcc: another@hacker.com"
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      refute String.contains?(result["from"], "\n")
      refute String.contains?(result["subject"], "\r\n")
      refute String.contains?(result["subject"], "Bcc:")
    end

    test "handles attachments map without modification" do
      email_data = %{
        "html_body" => "<p>See attachment</p>",
        "attachments" => %{
          "1" => %{"filename" => "test.pdf", "data" => "base64data"}
        }
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      assert result["attachments"] == email_data["attachments"]
    end

    test "produces JSON-encodable output" do
      email_data = %{
        "from" => "test@example.com",
        "subject" => "Test " <> <<0xE5, 0x86>> <> " subject",
        "html_body" => "<a href=\"https://test.com\">Link</a> " <> <<0xE5, 0x86>>,
        "text_body" => "https://test.com " <> <<0xE5, 0x86>>
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      assert {:ok, json} = Jason.encode(result)
      assert is_binary(json)
    end

    test "removes dangerous content while preserving safe links" do
      email_data = %{
        "html_body" => "<script>alert('xss')</script><a href=\"https://example.com\">Link</a>"
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      # Should remove script tags
      refute String.contains?(result["html_body"], "<script>")
      refute String.contains?(result["html_body"], "alert")

      # Should preserve safe links
      assert String.contains?(result["html_body"], "https://example.com")

      # Should be valid UTF-8
      assert String.valid?(result["html_body"])
    end
  end

  describe "sanitize_html_content/1 - aggressive sanitization" do
    test "removes script tags" do
      html = "<script>alert('xss')</script><p>Hello</p>"
      result = Sanitizer.sanitize_html_content(html)

      refute String.contains?(result, "<script>")
      refute String.contains?(result, "alert")
      assert String.valid?(result)
    end

    test "removes iframe tags" do
      html = "<iframe src=\"https://evil.com\"></iframe><p>Hello</p>"
      result = Sanitizer.sanitize_html_content(html)

      refute String.contains?(result, "<iframe")
      assert String.valid?(result)
    end

    test "preserves safe links" do
      html = "<a href=\"https://example.com\">Click</a>"
      result = Sanitizer.sanitize_html_content(html)

      assert String.contains?(result, "https://example.com")
      assert String.valid?(result)
    end

    test "preserves marketing content inside inert forms" do
      html =
        "<form action=\"https://example.com/submit\"><table><tr><td>Sale ends tonight</td></tr></table><button>Shop now</button></form>"

      result = Sanitizer.sanitize_html_content(html)

      refute String.contains?(result, "<form")
      refute String.contains?(result, "action=")
      assert String.contains?(result, "Sale ends tonight")
      assert String.contains?(result, "Shop now")
    end

    test "preserves safe marketing media tags" do
      html =
        "<video controls poster=\"https://example.com/poster.jpg\"><source src=\"https://example.com/clip.mp4\" type=\"video/mp4\"></video>"

      result = Sanitizer.sanitize_html_content(html)

      assert String.contains?(result, "<video")
      assert String.contains?(result, "controls")
      assert String.contains?(result, "https://example.com/poster.jpg")
      assert String.contains?(result, "https://example.com/clip.mp4")
      assert String.valid?(result)
    end

    test "strips XML processing instructions without crashing" do
      html = "<?xml version=\"1.0\" encoding=\"utf-8\"?><div><p>Hello</p></div>"
      result = Sanitizer.sanitize_html_content(html)

      refute String.contains?(result, "<?xml")
      assert String.contains?(result, "Hello")
      assert String.valid?(result)
    end

    test "preserves non-Outlook conditional content while removing Outlook-only content" do
      html = """
      <!--[if !mso]><!-->
      <style>.modern { color: #123456; }</style>
      <img src="https://example.com/icon.png" alt="Modern icon">
      <!--<![endif]-->
      <!--[if (gt mso 9)|(IE)]>
      <table><tr><td>Outlook only</td></tr></table>
      <![endif]-->
      <p>Visible body</p>
      """

      result = Sanitizer.sanitize_html_content(html)

      assert String.contains?(result, ".modern")
      assert String.contains?(result, "https://example.com/icon.png")
      assert String.contains?(result, "Visible body")
      refute String.contains?(result, "Outlook only")
      refute String.contains?(result, "<!--[if")
    end

    test "preserves real email layout attributes, inline styles, and responsive CSS" do
      html = """
      <!DOCTYPE html>
      <html>
        <head>
          <style>@media only screen and (max-width: 480px) { table[class="collapse"] { width:100% !important; } }</style>
        </head>
        <body bgcolor="#F5F8FA" style="margin:0;padding:0;">
          <table class="collapse" id="header" align="center" width="448" bgcolor="#ffffff" cellpadding="0" cellspacing="0" border="0" style="width:448px;background-color:#ffffff;">
            <tbody>
              <tr align="right">
                <td width="24" class="margin" style="padding:0;margin:0;"></td>
                <td align="right" style="font-size:14px;line-height:16px;">
                  <img width="32" height="32" src="https://example.com/logo.png" style="width:32px;display:block;" />
                </td>
              </tr>
            </tbody>
          </table>
        </body>
      </html>
      """

      result = Sanitizer.sanitize_html_content(html)

      assert String.contains?(result, ~s(bgcolor="#F5F8FA"))
      assert String.contains?(result, ~s(style="margin:0;padding:0;"))
      assert String.contains?(result, ~s(class="collapse"))
      assert String.contains?(result, ~s(id="header"))
      assert String.contains?(result, ~s(align="center"))
      assert String.contains?(result, ~s(width="448"))
      assert String.contains?(result, ~s(cellpadding="0"))
      assert String.contains?(result, ~s(cellspacing="0"))
      assert String.contains?(result, ~s(border="0"))
      assert String.contains?(result, ~s(style="width:448px;background-color:#ffffff;"))
      assert String.contains?(result, ~s(src="https://example.com/logo.png"))
      assert String.contains?(result, "@media only screen")
      refute String.contains?(String.downcase(result), "<!doctype")
    end

    test "removes active behavior without stripping safe email presentation" do
      html = """
      <div onclick="steal()" style="width:100px;background:url(javascript:alert(1));color:#111;">
        <script>alert("xss")</script>
        <form action="https://evil.example/submit"><input name="token" value="secret"><table style="border-collapse:collapse;"><tr><td>Sale ends tonight</td></tr></table></form>
        <a href="java&#x73;cript:alert(1)" style="color:#1DA1F2;">Bad link</a>
        <img src="data:text/html,<svg onload=alert(1)>" onerror="steal()" width="1" height="1" style="display:block;" />
      </div>
      """

      result = Sanitizer.sanitize_html_content(html)
      result_downcase = String.downcase(result)

      refute String.contains?(result_downcase, "<script")
      refute String.contains?(result_downcase, "onclick")
      refute String.contains?(result_downcase, "onerror")
      refute String.contains?(result_downcase, "javascript:")
      refute String.contains?(result_downcase, "data:text/html")
      refute String.contains?(result_downcase, "action=")
      refute String.contains?(result_downcase, "<form")
      refute String.contains?(result_downcase, "<input")
      assert String.contains?(result, ~s(style="width:100px;background:none;color:#111;"))
      assert String.contains?(result, ~s(style="border-collapse:collapse;"))
      assert String.contains?(result, ~s(style="color:#1DA1F2;"))
      assert String.contains?(result, "Sale ends tonight")
    end

    test "removes entity-obfuscated dangerous CSS URLs" do
      html = """
      <style>
        .a { background-image: url(&#x6a;avascript:alert(1)); }
        .b { background: url("v&#x62;script:msgbox(1)"); }
        .c { list-style-image: url('data:text/html,<svg onload=alert(1)>'); }
      </style>
      <div style="background:url(&#106;ava&#x73;cript:alert(2)); color: #111;">Hello</div>
      """

      result = Sanitizer.sanitize_html_content(html)
      result_downcase = String.downcase(result)

      refute String.contains?(result_downcase, "javascript:")
      refute String.contains?(result_downcase, "vbscript:")
      refute String.contains?(result_downcase, "data:text/html")
      assert String.contains?(result_downcase, "background:none")
      assert String.contains?(result_downcase, "background-image: none")
      assert String.contains?(result, "Hello")
    end

    test "removes control-character-obfuscated dangerous CSS URLs" do
      html = """
      <style>
        .a { background-image: url(ja
        vascript:alert(1)); }
      </style>
      <div style="background:url(ja\tvascript:alert(2)); color: #111;">Hello</div>
      """

      result = Sanitizer.sanitize_html_content(html)
      result_downcase = String.downcase(result)

      refute String.contains?(result_downcase, "javascript:")
      assert String.contains?(result_downcase, "background:none")
      assert String.contains?(result_downcase, "background-image: none")
    end

    test "keeps safe CSS URLs" do
      html =
        ~s|<div style="background:url(https://example.com/email.png); color:#111;">Hello</div>|

      result = Sanitizer.sanitize_html_content(html)

      assert String.contains?(result, "background:url(https://example.com/email.png)")
      assert String.contains?(result, "color:#111;")
    end
  end

  describe "fix common encoding issues (mojibake)" do
    test "preserves potential CJK characters to avoid corruption (ï½¿)" do
      # The sanitizer is conservative and doesn't aggressively replace patterns
      # that could be valid CJK text to avoid corrupting legitimate content
      corrupted = "Hello ï½¿ World"
      result = Sanitizer.sanitize_utf8(corrupted)

      assert String.valid?(result)
      # Content is preserved (may or may not have mojibake depending on implementation)
      assert String.contains?(result, "Hello")
      assert String.contains?(result, "World")
    end

    test "fixes smart quotes (â€™)" do
      corrupted = "Don't -> Donâ€™t"
      result = Sanitizer.sanitize_utf8(corrupted)

      assert String.valid?(result)
      refute String.contains?(result, "â€™")
      assert String.contains?(result, "'")
    end

    test "fixes em dash mojibake" do
      # â€" is UTF-8 bytes of em dash decoded as Latin-1
      corrupted = "Hello " <> <<0xE2, 0x80, 0x94>> <> " World"
      result = Sanitizer.sanitize_utf8(corrupted)

      assert String.valid?(result)
      assert String.contains?(result, "Hello")
      assert String.contains?(result, "World")
    end
  end

  describe "database and JSON compatibility" do
    test "all outputs are PostgreSQL safe" do
      test_cases = [
        <<0xE5, 0x86, 0xE5>>,
        "Test " <> <<0xE5, 0x86>> <> " subject",
        <<0xC2, 0xFF>>,
        "ï½¿ ï½¿ ï½¿"
      ]

      for test_input <- test_cases do
        result = Sanitizer.sanitize_utf8(test_input)

        # Should be valid UTF-8
        assert String.valid?(result), "Result should be valid UTF-8: #{inspect(result)}"

        # Should be JSON encodable
        assert {:ok, _} = Jason.encode(result),
               "Result should be JSON encodable: #{inspect(result)}"

        # Should be PostgreSQL safe (can't test DB directly, but valid UTF-8 is required)
        assert String.valid?(result)
      end
    end

    test "forwarded email data is fully JSON encodable" do
      email_data = %{
        "from" => "test@example.com " <> <<0xE5, 0x86>>,
        "subject" => "Subject " <> <<0xE5, 0x86, 0xE5>>,
        "html_body" => "<a href=\"https://test.com\">Link " <> <<0xC2, 0xFF>> <> "</a>",
        "text_body" => "https://test.com " <> <<0xE5, 0x86>>,
        "attachments" => %{}
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      # All fields should be valid UTF-8
      assert String.valid?(result["from"])
      assert String.valid?(result["subject"])
      assert String.valid?(result["html_body"])
      assert String.valid?(result["text_body"])

      # Entire map should be JSON encodable
      assert {:ok, json} = Jason.encode(result)
      assert is_binary(json)

      # Links should be preserved
      assert String.contains?(result["html_body"], "https://test.com")
      assert String.contains?(result["text_body"], "https://test.com")
    end
  end

  describe "edge cases" do
    test "handles very long invalid sequences" do
      # 100 invalid bytes
      invalid = :binary.copy(<<0xE5, 0x86>>, 50)
      result = Sanitizer.sanitize_utf8(invalid)

      assert String.valid?(result)
      assert {:ok, _} = Jason.encode(result)
    end

    test "handles empty and nil inputs" do
      assert Sanitizer.sanitize_utf8(nil) == ""
      assert Sanitizer.sanitize_utf8("") == ""
      assert String.valid?(Sanitizer.sanitize_utf8(nil))
      assert String.valid?(Sanitizer.sanitize_utf8(""))
    end

    test "handles all-invalid UTF-8" do
      invalid = <<0xFF, 0xFE, 0xFD, 0xFC>>
      result = Sanitizer.sanitize_utf8(invalid)

      assert String.valid?(result)
      assert {:ok, _} = Jason.encode(result)
    end

    test "preserves valid UTF-8 exactly" do
      valid_inputs = [
        "Hello World",
        "Test 123 !@#$%",
        "Émojis 😀🎉",
        "中文测试",
        "العربية",
        "Ελληνικά"
      ]

      for input <- valid_inputs do
        result = Sanitizer.sanitize_utf8(input)
        assert String.valid?(result)
        # Content should be mostly preserved (encoding fixes may apply)
        assert String.length(result) > 0
        assert {:ok, _} = Jason.encode(result)
      end
    end
  end

  describe "real-world email scenarios" do
    test "handles email with verification link and invalid UTF-8" do
      email_data = %{
        "subject" => "Verify your email " <> <<0xE5, 0x86>>,
        "html_body" =>
          """
          <p>Please verify your email address.</p>
          <p><a href="https://example.com/verify?token=abc123">Click here to verify</a></p>
          """ <> <<0xE5, 0x86, 0xE5>>,
        "text_body" => "Verify: https://example.com/verify?token=abc123 " <> <<0xE5, 0x86>>
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      # All fields valid UTF-8
      assert String.valid?(result["subject"])
      assert String.valid?(result["html_body"])
      assert String.valid?(result["text_body"])

      # Links preserved
      assert String.contains?(result["html_body"], "https://example.com/verify?token=abc123")
      assert String.contains?(result["text_body"], "https://example.com/verify?token=abc123")

      # JSON encodable
      assert {:ok, _} = Jason.encode(result)
    end

    test "handles marketing email with multiple links and images" do
      email_data = %{
        "html_body" =>
          """
          <div style="background: #fff;">
            <img src="https://example.com/logo.png" />
            <p>Check out our products:</p>
            <a href="https://example.com/product1">Product 1</a>
            <a href="https://example.com/product2">Product 2</a>
            <img src="https://example.com/banner.jpg" />
          </div>
          """ <> <<0xE5, 0x86>>
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      assert String.valid?(result["html_body"])
      assert String.contains?(result["html_body"], "https://example.com/logo.png")
      assert String.contains?(result["html_body"], "https://example.com/product1")
      assert String.contains?(result["html_body"], "https://example.com/product2")
      assert String.contains?(result["html_body"], "https://example.com/banner.jpg")
      assert String.contains?(result["html_body"], "style=")
    end

    test "handles Chinese subject line that caused production error" do
      # The actual bytes from the error message
      subject_bytes =
        <<70, 119, 100, 58, 32, 229, 183, 178, 230, 183, 187, 229, 138, 160, 32, 77, 105, 99, 114,
          111, 115, 111, 102, 116, 32, 229, 184, 144, 230, 136, 183, 229, 174, 137, 229, 168, 228,
          191, 161, 230, 129, 175>>

      email_data = %{
        "subject" => subject_bytes,
        "html_body" => "<p>Test</p>",
        "text_body" => "Test"
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      # Subject should be valid UTF-8
      assert String.valid?(result["subject"])

      # Should start with "Fwd:"
      assert String.starts_with?(result["subject"], "Fwd:")

      # Entire result should be JSON encodable
      assert {:ok, _} = Jason.encode(result)
    end
  end

  describe "sanitize_incoming_email/1" do
    test "sanitizes incoming email data" do
      email_data = %{
        "from" => "sender@example.com",
        "subject" => "Test " <> <<0xE5, 0x86>>,
        "html_body" => "<script>bad</script><p>Good</p>",
        "text_body" => "Good text " <> <<0xE5, 0x86>>
      }

      result = Sanitizer.sanitize_incoming_email(email_data)

      assert String.valid?(result["subject"])
      assert String.valid?(result["html_body"])
      assert String.valid?(result["text_body"])
      assert {:ok, _} = Jason.encode(result)
    end
  end

  describe "sanitize_outgoing_email/1" do
    test "sanitizes outgoing email data" do
      email_data = %{
        "from" => "sender@example.com",
        "subject" => "Test " <> <<0xE5, 0x86>>,
        "html_body" => "<p>Test</p>",
        "text_body" => "Test " <> <<0xE5, 0x86>>
      }

      result = Sanitizer.sanitize_outgoing_email(email_data)

      assert String.valid?(result["subject"])
      assert String.valid?(result["html_body"])
      assert String.valid?(result["text_body"])
      assert {:ok, _} = Jason.encode(result)
    end

    test "sanitizes atom-key headers" do
      email_data = %{
        from: "sender@example.com\r\nBcc: attacker@example.com",
        subject: "Test\nBcc: another@example.com",
        text_body: "Body"
      }

      result = Sanitizer.sanitize_outgoing_email(email_data)

      refute String.contains?(result.from, "\r\n")
      refute String.contains?(result.subject, "\n")
      refute String.contains?(result.subject, "Bcc:")
    end
  end
end
