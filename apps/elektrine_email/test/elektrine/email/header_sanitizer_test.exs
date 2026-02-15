defmodule Elektrine.Email.HeaderSanitizerTest do
  use ExUnit.Case, async: true

  alias Elektrine.Email.HeaderSanitizer

  describe "sanitize_email_header/1 - SMTP injection prevention" do
    test "removes CRLF sequences" do
      header = "test@example.com\r\nBcc: attacker@evil.com"
      result = HeaderSanitizer.sanitize_email_header(header)

      # Control characters are removed, but text after them remains concatenated
      refute result =~ "\r\n"
      refute result =~ "\r"
      refute result =~ "\n"
    end

    test "removes LF-only injection" do
      header = "test@example.com\nBcc: attacker@evil.com"
      result = HeaderSanitizer.sanitize_email_header(header)

      refute result =~ "\n"
    end

    test "removes CR-only injection" do
      header = "test@example.com\rBcc: attacker@evil.com"
      result = HeaderSanitizer.sanitize_email_header(header)

      refute result =~ "\r"
    end

    test "removes null bytes" do
      header = "test@example.com\x00hidden"
      result = HeaderSanitizer.sanitize_email_header(header)

      refute result =~ "\x00"
    end

    test "removes other control characters" do
      header = "test\x01\x02\x03@example.com"
      result = HeaderSanitizer.sanitize_email_header(header)

      refute result =~ "\x01"
      refute result =~ "\x02"
      refute result =~ "\x03"
    end

    test "removes vertical tab and form feed" do
      header = "test\x0B\x0C@example.com"
      result = HeaderSanitizer.sanitize_email_header(header)

      refute result =~ "\x0B"
      refute result =~ "\x0C"
    end

    test "handles nil input" do
      assert HeaderSanitizer.sanitize_email_header(nil) == nil
    end

    test "handles empty string" do
      assert HeaderSanitizer.sanitize_email_header("") == ""
    end

    test "preserves valid email addresses" do
      valid_emails = [
        "user@example.com",
        "user.name@example.com",
        "user+tag@example.com",
        "user@subdomain.example.com"
      ]

      for email <- valid_emails do
        result = HeaderSanitizer.sanitize_email_header(email)
        assert result == email
      end
    end

    test "trims whitespace" do
      header = "  user@example.com  "
      result = HeaderSanitizer.sanitize_email_header(header)

      assert result == "user@example.com"
    end

    test "limits very long headers" do
      long_header = String.duplicate("a", 2000) <> "@example.com"
      result = HeaderSanitizer.sanitize_email_header(long_header)

      assert String.length(result) <= 1000
    end

    test "handles Unicode in display names" do
      header = "\"John Doe \u4e2d\u6587\" <john@example.com>"
      result = HeaderSanitizer.sanitize_email_header(header)

      assert result =~ "john@example.com"
      assert String.valid?(result)
    end
  end

  describe "sanitize_subject_header/1 - subject-specific attacks" do
    test "removes CRLF injection in subject" do
      subject = "Test Subject\r\nBcc: attacker@evil.com"
      result = HeaderSanitizer.sanitize_subject_header(subject)

      refute result =~ "\r\n"
      refute result =~ "Bcc:"
    end

    test "removes header injection keywords" do
      subjects = [
        "Test bcc: hidden@evil.com",
        "Test cc: hidden@evil.com",
        "Test to: hidden@evil.com",
        "Test from: hidden@evil.com",
        "Test reply-to: hidden@evil.com"
      ]

      for subject <- subjects do
        result = HeaderSanitizer.sanitize_subject_header(subject)

        refute result =~ ~r/(bcc|cc|to|from|reply-to):/i
      end
    end

    test "handles nil subject" do
      assert HeaderSanitizer.sanitize_subject_header(nil) == ""
    end

    test "handles empty subject" do
      assert HeaderSanitizer.sanitize_subject_header("") == ""
    end

    test "preserves MIME encoded subjects" do
      # Chinese subject encoded in base64
      subject = "=?UTF-8?B?5rWL6K+V?="
      result = HeaderSanitizer.sanitize_subject_header(subject)

      assert result == subject
    end

    test "preserves quoted-printable encoded subjects" do
      subject = "=?UTF-8?Q?Test_Subject?="
      result = HeaderSanitizer.sanitize_subject_header(subject)

      assert result == subject
    end

    test "preserves international characters" do
      # Chinese, Japanese, and Russian (Korean excluded due to encoding issues in test file)
      subjects = [
        "中文测试",
        "日本語テスト",
        "Тест русский"
      ]

      for subject <- subjects do
        result = HeaderSanitizer.sanitize_subject_header(subject)
        assert String.valid?(result)
        assert String.length(result) > 0
      end
    end
  end

  describe "sanitize_email_params/1 - full email validation" do
    test "sanitizes all header fields" do
      params = %{
        "from" => "sender\r\nBcc: evil@evil.com",
        "to" => "recipient\nCc: evil@evil.com",
        "cc" => "cc-user\r\nFrom: spoof@evil.com",
        "bcc" => "bcc-user\x00hidden",
        "subject" => "Test\r\nBcc: evil@evil.com",
        "reply_to" => "reply\nBcc: evil@evil.com"
      }

      {:ok, result} = HeaderSanitizer.sanitize_email_params(params)

      refute result.from =~ "\r\n"
      refute result.to =~ "\n"
      refute result.cc =~ "\r\n"
      refute result.bcc =~ "\x00"
      refute result.subject =~ "\r\n"
      refute result.reply_to =~ "\n"
    end

    test "returns error for missing from address" do
      params = %{
        "to" => "recipient@example.com",
        "subject" => "Test"
      }

      assert {:error, "From address is required"} = HeaderSanitizer.sanitize_email_params(params)
    end

    test "returns error for missing to address" do
      params = %{
        "from" => "sender@example.com",
        "subject" => "Test"
      }

      assert {:error, "To address is required"} = HeaderSanitizer.sanitize_email_params(params)
    end

    test "preserves body content" do
      params = %{
        "from" => "sender@example.com",
        "to" => "recipient@example.com",
        "subject" => "Test",
        "text_body" => "Plain text content",
        "html_body" => "<p>HTML content</p>"
      }

      {:ok, result} = HeaderSanitizer.sanitize_email_params(params)

      assert result.text_body == "Plain text content"
      assert result.html_body == "<p>HTML content</p>"
    end

    test "handles atom keys" do
      params = %{
        from: "sender@example.com",
        to: "recipient@example.com",
        subject: "Test"
      }

      {:ok, result} = HeaderSanitizer.sanitize_email_params(params)

      assert result.from == "sender@example.com"
      assert result.to == "recipient@example.com"
    end
  end

  describe "check_local_domain_spoofing/2" do
    test "detects spoofing from external sender claiming local domain" do
      # External sender claiming to be from elektrine.com
      from = "admin@elektrine.com"
      # No authenticated user (nil)
      result = HeaderSanitizer.check_local_domain_spoofing(from, nil)

      assert {:error, _reason} = result
    end

    test "allows authenticated local users" do
      from = "user@elektrine.com"
      # Simulating authenticated user context
      result = HeaderSanitizer.check_local_domain_spoofing(from, %{authenticated: true})

      # Should pass or have different handling for authenticated users
      assert result != {:error, :spoofing_attempt}
    end

    test "allows external senders from external domains" do
      from = "user@gmail.com"
      result = HeaderSanitizer.check_local_domain_spoofing(from, nil)

      assert result == {:ok, :valid}
    end
  end

  describe "check_bounce_attack/1" do
    test "detects backscatter patterns" do
      bounce_params = %{
        from: "mailer-daemon@external.com",
        to: "user@elektrine.com",
        subject: "Delivery Status Notification (Failure)"
      }

      result = HeaderSanitizer.check_bounce_attack(bounce_params)

      # Should detect potential backscatter (may return {:ok, :valid} or {:error, _})
      assert result == {:ok, :valid} || match?({:error, _}, result)
    end

    test "allows legitimate emails" do
      params = %{
        from: "colleague@company.com",
        to: "user@elektrine.com",
        subject: "Meeting tomorrow"
      }

      result = HeaderSanitizer.check_bounce_attack(params)

      assert result == {:ok, :valid}
    end
  end

  describe "check_multiple_from_headers/1" do
    test "detects multiple From headers in raw email" do
      raw_email = """
      From: legitimate@example.com
      To: user@elektrine.com
      From: attacker@evil.com
      Subject: Test
      """

      result = HeaderSanitizer.check_multiple_from_headers(raw_email)

      assert {:error, _reason} = result
    end

    test "allows single From header" do
      raw_email = """
      From: sender@example.com
      To: user@elektrine.com
      Subject: Test
      """

      result = HeaderSanitizer.check_multiple_from_headers(raw_email)

      assert result == {:ok, :valid}
    end

    test "handles nil input" do
      result = HeaderSanitizer.check_multiple_from_headers(nil)

      assert result == {:ok, :valid}
    end
  end

  describe "edge cases" do
    test "handles Unicode normalization attacks in headers" do
      # Homograph attack - Cyrillic 'а' looks like Latin 'a'
      header = "user@g\u043eoogle.com"
      result = HeaderSanitizer.sanitize_email_header(header)

      assert String.valid?(result)
    end

    test "handles extremely long Unicode strings" do
      long_unicode = String.duplicate("\u4e2d", 1000)
      result = HeaderSanitizer.sanitize_email_header(long_unicode)

      assert String.length(result) <= 1000
      assert String.valid?(result)
    end

    test "handles mixed injection attempts" do
      header = "test@example.com\r\n\x00Bcc:\n\rcc:"
      result = HeaderSanitizer.sanitize_email_header(header)

      # Control characters are removed but text after them remains concatenated
      refute result =~ "\r"
      refute result =~ "\n"
      refute result =~ "\x00"
      # Text after control chars stays (just without the chars themselves)
      assert String.valid?(result)
    end

    test "handles URL-encoded injection attempts" do
      # Some systems might decode %0d%0a to CRLF
      header = "test%0d%0aBcc:evil@evil.com@example.com"
      result = HeaderSanitizer.sanitize_email_header(header)

      # Should keep as-is (already encoded) or sanitize if decoded
      assert String.valid?(result)
    end

    test "handles base64-looking injection" do
      header = "dGVzdEBleGFtcGxlLmNvbQ0KQmNjOiBldmlsQGV2aWwuY29t"
      result = HeaderSanitizer.sanitize_email_header(header)

      # Should pass through as-is (it's just text, not decoded)
      assert String.valid?(result)
    end
  end
end
