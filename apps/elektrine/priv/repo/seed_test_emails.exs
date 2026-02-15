# Script to seed test emails for categorization testing
# Run with: mix run priv/repo/seed_test_emails.exs

import Ecto.Query
alias Elektrine.{Repo, Email, Accounts}
alias Elektrine.Email.{Mailbox, Message}

# Get or create a test user
user =
  Accounts.get_user_by_username("sysadmin") ||
    Accounts.get_user_by_username("admin") ||
    Repo.one(Accounts.User, limit: 1)

if user do
  IO.puts("Using user: #{user.username}")

  # Ensure user has a mailbox
  {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
  IO.puts("Using mailbox: #{mailbox.email}")

  # Test emails data - each should go to a specific category
  test_emails = [
    # Should go to DIGEST (feed category)
    %{
      subject: "Your Medium Daily Digest",
      from: "noreply@medium.com",
      to: mailbox.email,
      text_body: "Here are today's top stories on Medium. Unsubscribe from these emails.",
      headers: %{"List-Unsubscribe" => "<mailto:unsubscribe@medium.com>"},
      expected_category: "feed",
      description: "Medium Daily Digest - should go to Digest"
    },
    %{
      subject: "Pangle Payment Reminder",
      from: "billing@pangle.io",
      to: mailbox.email,
      text_body: "Your next payment is due soon. Click here to manage your subscription.",
      headers: %{"List-Unsubscribe" => "<mailto:unsub@pangle.io>"},
      expected_category: "feed",
      description: "Pangle reminder - should go to Digest"
    },
    %{
      subject: "Weekly Newsletter from TechCrunch",
      from: "newsletter@techcrunch.com",
      to: mailbox.email,
      text_body: "This week in tech news. To unsubscribe, click here.",
      headers: %{"List-Id" => "techcrunch.list-id.com"},
      expected_category: "feed",
      description: "TechCrunch newsletter - should go to Digest"
    },
    %{
      subject: "GitHub Activity Report",
      from: "notifications@github.com",
      to: mailbox.email,
      text_body:
        "Here's what happened in your repositories this week. Manage your email preferences.",
      headers: %{"List-Unsubscribe" => "<https://github.com/settings/notifications>"},
      expected_category: "feed",
      description: "GitHub activity - should go to Digest"
    },

    # Should go to LEDGER
    %{
      subject: "Your Receipt from Amazon",
      from: "auto-confirm@amazon.com",
      to: mailbox.email,
      text_body: "Order #123-456789\nTotal: $49.99\nShipping Address: 123 Main St",
      headers: %{},
      expected_category: "ledger",
      description: "Amazon receipt - should go to Ledger"
    },
    %{
      subject: "Invoice #2024-001",
      from: "billing@company.com",
      to: mailbox.email,
      text_body: "Invoice Date: 2024-03-15\nAmount Due: $500.00\nPayment Due Date: 2024-04-15",
      headers: %{},
      expected_category: "ledger",
      description: "Invoice - should go to Ledger"
    },
    %{
      subject: "Payment Confirmation",
      from: "payments@stripe.com",
      to: mailbox.email,
      text_body: "Payment of $29.99 has been processed. Transaction ID: ch_123456",
      headers: %{},
      expected_category: "ledger",
      description: "Stripe payment - should go to Ledger"
    },

    # Should stay in INBOX
    %{
      subject: "Meeting tomorrow at 3pm",
      from: "john.doe@example.com",
      to: mailbox.email,
      text_body:
        "Hey, just wanted to confirm our meeting tomorrow. Let me know if you need to reschedule.",
      headers: %{},
      expected_category: "inbox",
      description: "Personal email - should stay in Inbox"
    },
    %{
      subject: "Password Reset Request",
      from: "security@yourbank.com",
      to: mailbox.email,
      text_body:
        "You requested a password reset. Your verification code is: 123456. This code expires in 10 minutes.",
      headers: %{},
      expected_category: "inbox",
      description: "Security notification - should stay in Inbox"
    },
    %{
      subject: "AWS Account Risk - Immediate Action Required",
      from: "no-reply@amazonaws.com",
      to: mailbox.email,
      text_body:
        "We've detected unusual activity on your AWS account. Please review immediately.",
      headers: %{},
      expected_category: "inbox",
      description: "AWS critical alert - should stay in Inbox"
    },

    # Edge cases - bulk emails that look like receipts
    %{
      subject: "Your Spotify Premium Receipt",
      from: "no-reply@spotify.com",
      to: mailbox.email,
      text_body:
        "Thanks for your payment of $9.99. Your subscription continues. Manage preferences or unsubscribe.",
      headers: %{"List-Unsubscribe" => "<mailto:unsub@spotify.com>"},
      expected_category: "ledger",
      description: "Spotify subscription receipt - should go to Ledger (receipt wins over bulk)"
    },
    %{
      subject: "Medium Membership Payment Processed",
      from: "noreply@medium.com",
      to: mailbox.email,
      text_body:
        "Your payment of $5/month has been processed. Read unlimited stories. Unsubscribe anytime.",
      headers: %{"List-Unsubscribe" => "<mailto:unsubscribe@medium.com>"},
      expected_category: "ledger",
      description: "Medium payment - should go to Ledger (payment receipt)"
    }
  ]

  IO.puts("\n=== Creating test emails ===\n")

  # Create each test email
  Enum.each(test_emails, fn email_data ->
    attrs = %{
      "message_id" => "test_#{:rand.uniform(1_000_000)}",
      "from" => email_data.from,
      "to" => email_data.to,
      "subject" => email_data.subject,
      "text_body" => email_data.text_body,
      # Simple HTML for testing
      "html_body" => email_data.text_body,
      "status" => "received",
      "read" => false,
      "spam" => false,
      "archived" => false,
      "mailbox_id" => mailbox.id,
      "metadata" => %{"headers" => email_data.headers}
    }

    case Email.create_message(attrs) do
      {:ok, message} ->
        if message.category == email_data.expected_category do
          IO.puts("✅ #{email_data.description}")
          IO.puts("   Category: #{message.category} (CORRECT)")
        else
          IO.puts("❌ #{email_data.description}")
          IO.puts("   Category: #{message.category} (EXPECTED: #{email_data.expected_category})")
        end

        IO.puts(
          "   Newsletter: #{message.is_newsletter}, Receipt: #{message.is_receipt}, Notification: #{message.is_notification}"
        )

        IO.puts("")

      {:error, changeset} ->
        IO.puts("❌ Failed to create: #{email_data.description}")
        IO.puts(inspect(changeset.errors, pretty: true))
        IO.puts("")
    end
  end)

  IO.puts("\n=== Summary ===")

  # Show counts by category
  inbox_count =
    Repo.one(
      from m in Message,
        where: m.mailbox_id == ^mailbox.id and m.category == "inbox",
        select: count(m.id)
    )

  feed_count =
    Repo.one(
      from m in Message,
        where: m.mailbox_id == ^mailbox.id and m.category == "feed",
        select: count(m.id)
    )

  ledger_count =
    Repo.one(
      from m in Message,
        where: m.mailbox_id == ^mailbox.id and m.category == "ledger",
        select: count(m.id)
    )

  IO.puts("Inbox: #{inbox_count} messages")
  IO.puts("Digest (feed): #{feed_count} messages")
  IO.puts("Ledger: #{ledger_count} messages")

  IO.puts("\nTo test the recategorizer job manually, run:")
  IO.puts("iex> Elektrine.Jobs.EmailRecategorizer.run()")
else
  IO.puts("No user found. Please create a user first.")
end
