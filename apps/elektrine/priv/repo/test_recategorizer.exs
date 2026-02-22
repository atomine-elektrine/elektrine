# Test script for the recategorizer - intentionally miscategorize emails
# Run with: mix run priv/repo/test_recategorizer.exs

import Ecto.Query
alias Elektrine.Email.{Mailbox, Message}
alias Elektrine.{Accounts, Email, Repo}

# Get or create a test user
user =
  Accounts.get_user_by_username("sysadmin") ||
    Accounts.get_user_by_username("admin") ||
    Repo.one(Accounts.User, limit: 1)

if user do
  IO.puts("Using user: #{user.username}")

  # Ensure user has a mailbox
  {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
  IO.puts("Using mailbox: #{mailbox.email}\n")

  # Clear existing messages
  Repo.delete_all(Message)
  IO.puts("Cleared existing messages\n")

  # Create emails with WRONG categories on purpose
  miscategorized_emails = [
    # Should be in FEED but we'll put in INBOX
    %{
      subject: "Your Medium Daily Digest - Top Stories Today",
      from: "noreply@medium.com",
      # WRONG!
      forced_category: "inbox",
      correct_category: "feed",
      headers: %{"List-Unsubscribe" => "<mailto:unsubscribe@medium.com>"}
    },
    %{
      subject: "GitHub Activity - 5 new notifications",
      from: "notifications@github.com",
      # WRONG!
      forced_category: "inbox",
      correct_category: "feed",
      headers: %{"List-Unsubscribe" => "<https://github.com/settings/notifications>"}
    },
    %{
      subject: "TechCrunch Newsletter - This Week in Tech",
      from: "newsletter@techcrunch.com",
      # WRONG!
      forced_category: "ledger",
      correct_category: "feed",
      headers: %{"List-Id" => "techcrunch.list-id.com"}
    },

    # Should be in LEDGER but we'll put in INBOX
    %{
      subject: "Your Amazon Order #123-456789",
      from: "auto-confirm@amazon.com",
      # WRONG!
      forced_category: "inbox",
      correct_category: "ledger",
      headers: %{}
    },
    %{
      subject: "Receipt for your Uber ride",
      from: "receipts@uber.com",
      # WRONG!
      forced_category: "feed",
      correct_category: "ledger",
      headers: %{}
    },

    # Should stay in INBOX (personal email) but we'll put elsewhere
    %{
      subject: "Meeting tomorrow at 3pm?",
      from: "john.smith@example.com",
      # WRONG!
      forced_category: "feed",
      correct_category: "inbox",
      headers: %{}
    }
  ]

  IO.puts("=== Creating intentionally miscategorized emails ===\n")

  # Create each email with the WRONG category
  created_ids =
    Enum.map(miscategorized_emails, fn email_data ->
      # Create message directly with wrong category (bypass categorizer)
      {:ok, message} =
        Repo.insert(%Message{
          message_id: "test_#{:rand.uniform(1_000_000)}",
          from: email_data.from,
          to: mailbox.email,
          subject: email_data.subject,
          text_body: "Test email body with some content. Unsubscribe link here.",
          html_body: "<p>Test email body</p>",
          status: "received",
          read: false,
          spam: false,
          archived: false,
          mailbox_id: mailbox.id,
          # Force wrong category
          category: email_data.forced_category,
          is_newsletter: false,
          is_receipt: false,
          is_notification: false,
          metadata: %{"headers" => email_data.headers}
        })

      IO.puts("❌ Created '#{String.slice(email_data.subject, 0, 40)}...'")
      IO.puts("   From: #{email_data.from}")

      IO.puts(
        "   Forced category: #{email_data.forced_category} (should be #{email_data.correct_category})"
      )

      IO.puts("")

      {message.id, email_data.correct_category}
    end)

  # Show current state
  IO.puts("\n=== Current state (BEFORE recategorization) ===")

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

  IO.puts("Inbox: #{inbox_count} messages (should be 1)")
  IO.puts("Feed: #{feed_count} messages (should be 3)")
  IO.puts("Ledger: #{ledger_count} messages (should be 2)")

  # Now run the recategorizer
  IO.puts("\n=== Running EmailRecategorizer job ===\n")
  Elektrine.Jobs.EmailRecategorizer.run()

  # Check results after recategorization
  IO.puts("\n=== Results AFTER recategorization ===\n")

  Enum.each(created_ids, fn {id, expected_category} ->
    message = Repo.get!(Message, id)

    if message.category == expected_category do
      IO.puts("✅ Message #{id}: '#{String.slice(message.subject, 0, 30)}...'")
      IO.puts("   Now in: #{message.category} (CORRECT!)")
    else
      IO.puts("❌ Message #{id}: '#{String.slice(message.subject, 0, 30)}...'")
      IO.puts("   Still in: #{message.category} (expected #{expected_category})")
    end

    IO.puts(
      "   Flags - Newsletter: #{message.is_newsletter}, Receipt: #{message.is_receipt}, Notification: #{message.is_notification}"
    )

    IO.puts("")
  end)

  # Final counts
  IO.puts("\n=== Final category counts ===")

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

  IO.puts(
    "Inbox: #{inbox_count} messages (should be 1) #{if inbox_count == 1, do: "✅", else: "❌"}"
  )

  IO.puts("Feed: #{feed_count} messages (should be 3) #{if feed_count == 3, do: "✅", else: "❌"}")

  IO.puts(
    "Ledger: #{ledger_count} messages (should be 2) #{if ledger_count == 2, do: "✅", else: "❌"}"
  )
else
  IO.puts("No user found. Please create a user first.")
end
