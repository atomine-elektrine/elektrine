defmodule Mix.Tasks.Email.SeedPlaintext do
  @shortdoc "Seeds test plaintext emails for testing display and formatting"

  use Mix.Task
  alias Elektrine.Email
  alias Elektrine.Repo

  @moduledoc """
  Mix task to seed test plaintext emails for display testing.

  Usage:
    mix email.seed_plaintext [username]
    
  Examples:
    mix email.seed_plaintext              # Seeds to first user
    mix email.seed_plaintext maxfield     # Seeds to specific user
  """

  def run(args) do
    Mix.Task.run("app.start")

    username =
      case args do
        [user] ->
          user

        [] ->
          get_first_user_username()

        _ ->
          Mix.shell().error("Usage: mix email.seed_plaintext [username]")
          System.halt(1)
      end

    case Elektrine.Accounts.get_user_by_username(username) do
      nil ->
        Mix.shell().error("User '#{username}' not found")
        System.halt(1)

      user ->
        seed_plaintext_emails(user)
    end
  end

  defp get_first_user_username do
    case Repo.all(Elektrine.Accounts.User, limit: 1) do
      [user | _] ->
        user.username

      [] ->
        Mix.shell().error("No users found in database")
        System.halt(1)
    end
  end

  defp seed_plaintext_emails(user) do
    mailbox = Email.get_user_mailbox(user.id)

    if mailbox do
      Mix.shell().info("Seeding plaintext test emails for #{user.username}@elektrine.com...")

      test_emails()
      |> Enum.each(fn email_data ->
        attrs = Map.put(email_data, :mailbox_id, mailbox.id)

        case Email.create_message(attrs) do
          {:ok, _message} ->
            Mix.shell().info("✓ Created: #{email_data.subject}")

          {:error, changeset} ->
            Mix.shell().error("✗ Failed: #{email_data.subject} - #{inspect(changeset.errors)}")
        end
      end)

      Mix.shell().info("Plaintext email seeding completed!")
    else
      Mix.shell().error("No mailbox found for user #{user.username}")
      System.halt(1)
    end
  end

  defp test_emails do
    [
      %{
        message_id: "plaintext-test-1-#{System.unique_integer([:positive])}@elektrine.com",
        from: "alice@example.com",
        to: "test@elektrine.com",
        subject: "Simple plaintext message",
        text_body:
          "Hello! This is a simple plaintext email with no HTML formatting.\n\nIt has multiple paragraphs and should display with proper line breaks.\n\nBest regards,\nAlice",
        html_body: nil,
        status: "received"
      },
      %{
        message_id: "plaintext-test-2-#{System.unique_integer([:positive])}@elektrine.com",
        from: "support@techcompany.com",
        to: "test@elektrine.com",
        subject: "Code snippet and formatting test",
        text_body: """
        Hi there,

        Here's some code for you to review:

        def hello_world do
          IO.puts("Hello, World!")
        end

        And here's a list of items:
        - First item
        - Second item  
        - Third item

        Some ASCII art:
        ┌─────────────┐
        │   SUCCESS   │
        └─────────────┘

        Long lines should wrap properly: Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.

        Thanks!
        Support Team
        """,
        html_body: nil,
        status: "received"
      },
      %{
        message_id: "plaintext-test-3-#{System.unique_integer([:positive])}@elektrine.com",
        from: "newsletter@community.org",
        to: "test@elektrine.com",
        subject: "Weekly newsletter with mixed content",
        text_body: """
        WEEKLY COMMUNITY NEWSLETTER
        ===========================

        Welcome to this week's update!

        📰 TOP STORIES:
        ---------------
        • Major breakthrough in quantum computing
        • New programming language releases
        • Community event announcements

        🎯 FEATURED PROJECT:
        -------------------
        Project Name: Elektrine Email Platform
        Description: A modern email system with smart categorization
        GitHub: https://github.com/example/elektrine

        💻 CODE SNIPPET OF THE WEEK:
        ----------------------------
        # Elixir pattern matching
        case user_input do
          {:ok, data} -> process_data(data)
          {:error, reason} -> handle_error(reason)
          _ -> default_action()
        end

        🔗 USEFUL LINKS:
        ----------------
        - Documentation: https://docs.example.com
        - Community Forum: https://forum.example.com  
        - Support: support@example.com

        That's all for this week! See you next time.

        ---
        Unsubscribe: https://example.com/unsubscribe
        """,
        html_body: nil,
        status: "received",
        is_newsletter: true
      },
      %{
        message_id: "plaintext-test-4-#{System.unique_integer([:positive])}@elektrine.com",
        from: "system@bank.com",
        to: "test@elektrine.com",
        subject: "Account statement - Transaction details",
        text_body: """
        ACCOUNT STATEMENT
        =================

        Account Number: ****-****-****-1234
        Statement Period: September 1-30, 2025

        TRANSACTION SUMMARY:
        -------------------
        Opening Balance:     $1,250.00
        Total Deposits:      $2,500.00
        Total Withdrawals:   $  750.00
        Closing Balance:     $3,000.00

        RECENT TRANSACTIONS:
        -------------------
        09/25  DEPOSIT    Online Transfer        +$1,500.00
        09/24  PURCHASE   Coffee Shop            -$   4.50  
        09/23  PURCHASE   Gas Station            -$  45.00
        09/22  DEPOSIT    Salary Direct Deposit  +$1,000.00
        09/20  PURCHASE   Grocery Store          -$  89.25

        IMPORTANT NOTICE:
        ----------------
        Your account is in good standing. 

        If you have any questions about your account, please contact us at:
        Phone: 1-800-555-BANK
        Email: support@bank.com
        Website: https://bank.com/support

        Thank you for banking with us!

        ---
        This is an automated message. Please do not reply to this email.
        """,
        html_body: nil,
        status: "received",
        is_receipt: true
      },
      %{
        message_id: "plaintext-test-5-#{System.unique_integer([:positive])}@elektrine.com",
        from: "notifications@platform.com",
        to: "test@elektrine.com",
        subject: "Security alert: New login detected",
        text_body: """
        SECURITY ALERT
        ==============

        We detected a new login to your account:

        Time: September 10, 2025 at 2:30 PM PST
        Location: San Francisco, CA, USA
        Device: Chrome on macOS
        IP Address: 192.168.1.100

        Was this you?

        If you recognize this activity, you can ignore this message.

        If you don't recognize this activity:
        1. Change your password immediately
        2. Review your account for suspicious activity  
        3. Contact our support team

        IMMEDIATE ACTIONS:
        • Change Password: https://platform.com/change-password
        • Review Activity: https://platform.com/security
        • Contact Support: security@platform.com

        For your security, this is an automated message that cannot be replied to.

        Stay safe!
        Platform Security Team
        """,
        html_body: nil,
        status: "received",
        is_notification: true
      }
    ]
  end
end
