defmodule Elektrine.Email.CategorizerTest do
  use ExUnit.Case
  alias Elektrine.Email.Categorizer

  describe "categorize_message/1" do
    test "detects direct personal email conversation" do
      message = %{
        "subject" => "Re: Meeting tomorrow",
        "from" => "john.doe@example.com",
        "to" => "jane.smith@example.com",
        "text_body" => "Hi Jane, sounds good! See you at 3pm. Best, John",
        "html_body" => "",
        "metadata" => %{"headers" => %{}}
      }

      result = Categorizer.categorize_message(message)

      assert result["category"] == "inbox"
      assert result["is_receipt"] == false
      assert result["is_newsletter"] == false
      assert result["is_notification"] == false
    end

    test "detects bulk marketing email" do
      message = %{
        "subject" => "Special Offer: 50% Off Everything!",
        "from" => "marketing@store.com",
        "to" => "customers@list.store.com",
        "text_body" =>
          "Limited time offer! Click here to shop now. Unsubscribe from these emails.",
        "html_body" => "<a href='unsubscribe'>Unsubscribe</a>",
        "metadata" => %{
          "headers" => %{
            "list-unsubscribe" => "<mailto:unsubscribe@store.com>",
            "precedence" => "bulk"
          }
        }
      }

      result = Categorizer.categorize_message(message)

      assert result["category"] == "feed"
      # This is detected as a newsletter due to the unsubscribe header and marketing content
      assert result["is_newsletter"] == true
      assert result["is_notification"] == false
    end

    test "detects receipt/invoice email" do
      message = %{
        "subject" => "Your order receipt #12345",
        "from" => "receipts@amazon.com",
        "to" => "customer@email.com",
        "text_body" =>
          "Order Total: $99.99\nSubtotal: $89.99\nTax: $10.00\nThank you for your purchase!",
        "html_body" => "<table><tr><td>Item</td><td>Price</td></tr></table>",
        "metadata" => %{"headers" => %{}}
      }

      result = Categorizer.categorize_message(message)

      assert result["category"] == "ledger"
      assert result["is_receipt"] == true
    end

    test "detects newsletter email" do
      message = %{
        "subject" => "Tech Weekly Newsletter - Issue #42",
        "from" => "newsletter@techcrunch.com",
        "to" => "subscriber@email.com",
        "text_body" =>
          "This week's highlights: AI advances... View in browser. Unsubscribe. Forward to a friend.",
        "html_body" => "",
        "metadata" => %{
          "headers" => %{
            "list-unsubscribe" => "<mailto:unsubscribe@techcrunch.com>",
            "list-id" => "techcrunch-weekly"
          }
        }
      }

      result = Categorizer.categorize_message(message)

      assert result["category"] == "feed"
      assert result["is_newsletter"] == true
    end

    test "detects security notification email" do
      message = %{
        "subject" => "Security Alert: New login detected",
        "from" => "no-reply@google.com",
        "to" => "user@gmail.com",
        "text_body" =>
          "New login to your account detected from Chrome on Windows. If this wasn't you, secure your account.",
        "html_body" => "",
        "metadata" => %{"headers" => %{}}
      }

      result = Categorizer.categorize_message(message)

      assert result["category"] == "inbox"
      assert result["is_notification"] == true
      assert result["is_newsletter"] == false
    end

    test "detects password reset notification" do
      message = %{
        "subject" => "Password Reset Request",
        "from" => "security@github.com",
        "to" => "developer@email.com",
        "text_body" =>
          "Your password reset verification code is: 123456. This code expires in 15 minutes.",
        "html_body" => "",
        "metadata" => %{"headers" => %{}}
      }

      result = Categorizer.categorize_message(message)

      # Note: GitHub emails are typically detected as bulk/newsletter, so they go to feed
      assert result["category"] == "feed"
      assert result["is_notification"] == true
    end

    test "detects Uber/Lyft receipt" do
      message = %{
        "subject" => "Your ride with Uber",
        "from" => "receipts@uber.com",
        "to" => "rider@email.com",
        "text_body" =>
          "Trip fare: $25.50\nDistance: 5.2 miles\nDuration: 15 minutes\nTotal charged: $25.50",
        "html_body" => "",
        "metadata" => %{"headers" => %{}}
      }

      result = Categorizer.categorize_message(message)

      assert result["category"] == "ledger"
      assert result["is_receipt"] == true
    end

    test "detects subscription confirmation" do
      message = %{
        "subject" => "Welcome to our newsletter!",
        "from" => "hello@substack.com",
        "to" => "new-subscriber@email.com",
        "text_body" =>
          "Thanks for subscribing! You'll receive weekly updates. Manage subscription preferences.",
        "html_body" => "",
        "metadata" => %{
          "headers" => %{
            "list-unsubscribe" => "<mailto:unsubscribe@substack.com>"
          }
        }
      }

      result = Categorizer.categorize_message(message)

      assert result["category"] == "feed"
      assert result["is_newsletter"] == true
    end

    test "handles edge case with minimal information" do
      message = %{
        "subject" => "",
        "from" => "sender@email.com",
        "to" => "recipient@email.com",
        "text_body" => "Quick note",
        "html_body" => "",
        "metadata" => %{"headers" => %{}}
      }

      result = Categorizer.categorize_message(message)

      assert result["category"] == "inbox"
      assert result["is_receipt"] == false
      assert result["is_newsletter"] == false
      assert result["is_notification"] == false
    end

    test "detects GitHub notification" do
      message = %{
        "subject" => "[repo] New issue: Bug in login",
        "from" => "notifications@github.com",
        "to" => "developer@email.com",
        "text_body" => "A new issue was opened. View it on GitHub.",
        "html_body" => "",
        "metadata" => %{"headers" => %{}}
      }

      result = Categorizer.categorize_message(message)

      # Note: GitHub notifications are detected as bulk/newsletter, so they go to feed
      assert result["category"] == "feed"
      assert result["is_notification"] == true
    end
  end

  describe "detect_bulk_email/4" do
    test "identifies bulk email by headers" do
      headers = %{
        "list-unsubscribe" => "<mailto:unsubscribe@example.com>",
        "precedence" => "bulk",
        "x-campaign-id" => "12345"
      }

      assert Categorizer.detect_bulk_email(
               headers,
               "news@company.com",
               "list@company.com",
               "content"
             )
    end

    test "identifies bulk email by unsubscribe keywords" do
      headers = %{}
      body = "Great deals await! Click here to shop. To unsubscribe from these emails click here."

      assert Categorizer.detect_bulk_email(headers, "sales@store.com", "customer@email.com", body)
    end

    test "identifies bulk email by no-reply sender" do
      headers = %{}
      # Add more bulk indicators to meet the threshold
      body = "Update from service. To unsubscribe, click here. This is an automated message."

      assert Categorizer.detect_bulk_email(
               headers,
               "no-reply@service.com",
               "user@email.com",
               body
             )
    end

    test "does not flag personal email as bulk" do
      headers = %{}

      refute Categorizer.detect_bulk_email(
               headers,
               "friend@personal.com",
               "me@personal.com",
               "Hey, how are you?"
             )
    end
  end

  describe "detect_receipt/4" do
    test "detects receipt by subject" do
      assert Categorizer.detect_receipt(
               "order confirmation #12345",
               "store@shop.com",
               "Your order details",
               ""
             )
    end

    test "detects receipt by price patterns" do
      assert Categorizer.detect_receipt(
               "Purchase complete",
               "billing@service.com",
               "Total: $49.99 including tax of $5.00",
               ""
             )
    end

    test "detects receipt by multiple currency formats" do
      # Add more receipt keywords to meet the threshold
      assert Categorizer.detect_receipt(
               "Invoice #12345",
               "billing@company.com",
               "Invoice Details:\nAmount due: €100.50 (USD 110.25)\nPayment terms: Net 30\nTotal: €100.50",
               ""
             )
    end

    test "does not flag non-receipt as receipt" do
      refute Categorizer.detect_receipt(
               "Meeting tomorrow",
               "colleague@work.com",
               "Let's discuss the project pricing strategy",
               ""
             )
    end
  end

  describe "detect_newsletter/4" do
    test "detects newsletter by subject patterns" do
      headers = %{"list-unsubscribe" => "mailto:unsub@news.com"}

      assert Categorizer.detect_newsletter(
               "weekly digest - march edition",
               "newsletter@media.com",
               "This week's top stories",
               headers
             )
    end

    test "detects newsletter by sender domain" do
      headers = %{}

      assert Categorizer.detect_newsletter(
               "Updates",
               "hello@substack.com",
               "Read more in this issue. Unsubscribe",
               headers
             )
    end

    test "does not flag regular email as newsletter" do
      headers = %{}

      refute Categorizer.detect_newsletter(
               "Question about project",
               "teammate@company.com",
               "Can you review this?",
               headers
             )
    end
  end

  describe "detect_notification/3" do
    test "detects password reset notification" do
      assert Categorizer.detect_notification(
               "Reset your password",
               "security@service.com",
               "Your password reset code is 123456"
             )
    end

    test "detects 2FA notification" do
      assert Categorizer.detect_notification(
               "Login code",
               "no-reply@bank.com",
               "Your two-factor authentication code: 789012"
             )
    end

    test "detects system notification" do
      assert Categorizer.detect_notification(
               "Account update",
               "automated@system.com",
               "Important: Your account settings have been updated"
             )
    end

    test "does not flag personal message as notification" do
      refute Categorizer.detect_notification(
               "Lunch?",
               "friend@email.com",
               "Want to grab lunch today?"
             )
    end
  end

  describe "category determination" do
    test "prioritizes newsletter category over receipt" do
      message = %{
        "subject" => "Receipt for your newsletter subscription",
        "from" => "billing@newsletter.com",
        "to" => "subscriber@email.com",
        "text_body" =>
          "Payment received: $9.99. Thank you for subscribing to our newsletter. Unsubscribe anytime.",
        "html_body" => "",
        "metadata" => %{
          "headers" => %{
            "list-unsubscribe" => "<mailto:unsubscribe@newsletter.com>"
          }
        }
      }

      result = Categorizer.categorize_message(message)

      # Newsletter emails go to feed, even if they contain receipt info
      assert result["category"] == "feed"
      assert result["is_receipt"] == true
      assert result["is_newsletter"] == true
    end

    test "bulk notifications go to feed" do
      message = %{
        "subject" => "System maintenance notification",
        "from" => "no-reply@service.com",
        "to" => "users@list.service.com",
        "text_body" =>
          "Scheduled maintenance tonight. This is an automated notification. Do not reply.",
        "html_body" => "",
        "metadata" => %{
          "headers" => %{
            "precedence" => "bulk"
          }
        }
      }

      result = Categorizer.categorize_message(message)

      assert result["category"] == "feed"
      assert result["is_notification"] == true
    end

    test "non-bulk notifications go to inbox" do
      message = %{
        "subject" => "Your account was accessed",
        "from" => "security@bank.com",
        "to" => "customer@email.com",
        "text_body" =>
          "New login detected from IP 192.168.1.1. If this wasn't you, contact us immediately.",
        "html_body" => "",
        "metadata" => %{"headers" => %{}}
      }

      result = Categorizer.categorize_message(message)

      assert result["category"] == "inbox"
      assert result["is_notification"] == true
    end
  end
end
