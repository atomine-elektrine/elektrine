defmodule Mix.Tasks.Email.Test do
  use Mix.Task
  require Logger

  @shortdoc "Test the email system by sending and receiving test emails"

  def run(_) do
    # Start the application
    Mix.shell().info("Starting the application...")
    Mix.Task.run("app.start")

    # Get a user to test with
    user =
      case Elektrine.Accounts.list_users() do
        [user | _] -> user
        [] -> create_test_user()
      end

    # Ensure the user has a mailbox
    mailbox =
      Elektrine.Email.get_user_mailbox(user.id) ||
        create_test_mailbox(user)

    Mix.shell().info("Using mailbox: #{mailbox.email}")

    # Test sending an email
    test_send_email(mailbox)

    # Test receiving an email
    test_receive_email(mailbox)

    Mix.shell().info("Email tests completed! Check the mailbox.")
  end

  defp create_test_user do
    Mix.shell().info("Creating a test user...")

    {:ok, user} =
      Elektrine.Accounts.create_user(%{
        username: "testuser",
        password: "password123",
        password_confirmation: "password123"
      })

    user
  end

  defp create_test_mailbox(user) do
    Mix.shell().info("Creating a test mailbox...")

    {:ok, mailbox} = Elektrine.Email.create_mailbox(user)
    mailbox
  end

  defp test_send_email(mailbox) do
    Mix.shell().info("Testing email sending...")

    # Send a test email to the same mailbox (loopback test)
    params = %{
      from: mailbox.email,
      to: mailbox.email,
      subject: "Test Email #{DateTime.utc_now()}",
      text_body: "This is a test email sent from the Elektrine email system.",
      html_body:
        "<p>This is a <strong>test email</strong> sent from the Elektrine email system.</p>"
    }

    case Elektrine.Email.HarakaClient.send_email(params) do
      {:ok, result} ->
        Mix.shell().info("Email sent successfully! Message ID: #{result.message_id}")

      {:error, reason} ->
        Mix.shell().error("Failed to send email: #{inspect(reason)}")
    end
  end

  defp test_receive_email(mailbox) do
    Mix.shell().info("Testing email receiving (via webhook)...")

    # Create a mock webhook payload
    webhook_payload = %{
      "id" => "test-#{System.system_time(:millisecond)}",
      "from" => "test-sender@example.com",
      "to" => mailbox.email,
      "subject" => "Test Webhook Email #{DateTime.utc_now()}",
      "text_part" => "This is a test email received via webhook.",
      "html_part" => "<p>This is a <strong>test email</strong> received via webhook.</p>",
      "received_with_ssl" => true
    }

    # Process the webhook
    case ElektrineWeb.HarakaWebhookController.create(
           webhook_payload["text_part"],
           webhook_payload["to"]
         ) do
      {:ok, message} ->
        Mix.shell().info("Test email received successfully! Message ID: #{message.id}")

      {:error, reason} ->
        Mix.shell().error("Failed to process test email: #{inspect(reason)}")
    end
  end
end
