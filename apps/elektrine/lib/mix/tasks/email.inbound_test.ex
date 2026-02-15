defmodule Mix.Tasks.Email.InboundTest do
  use Mix.Task
  require Logger

  @shortdoc "Test the Postal inbound email processing"

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

    # Test receiving an email via the inbound endpoint
    test_inbound_email(mailbox)

    Mix.shell().info("Inbound email test completed! Check the mailbox.")
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

  defp test_inbound_email(mailbox) do
    Mix.shell().info("Testing inbound email processing...")

    # Create a sample raw email
    date = DateTime.utc_now() |> DateTime.to_string()
    message_id = "<test-#{System.system_time(:millisecond)}@example.com>"

    raw_email = """
    From: test-sender@example.com
    To: #{mailbox.email}
    Subject: Test Inbound Email #{DateTime.utc_now()}
    Message-ID: #{message_id}
    Date: #{date}
    MIME-Version: 1.0
    Content-Type: multipart/alternative; boundary="boundary-string"

    --boundary-string
    Content-Type: text/plain; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    This is a test inbound email.
    It was generated to test the Postal inbound email processing.

    --boundary-string
    Content-Type: text/html; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    <html>
    <head>
      <title>Test Inbound Email</title>
    </head>
    <body>
      <p>This is a <strong>test inbound email</strong>.</p>
      <p>It was generated to test the Postal inbound email processing.</p>
    </body>
    </html>

    --boundary-string--
    """

    # Encode the email in Base64
    base64_message = Base.encode64(raw_email)

    # Call the controller directly
    params = %{"message" => base64_message}

    # Create a fake connection for testing
    conn = %Plug.Conn{
      remote_ip: {127, 0, 0, 1},
      req_headers: [{"x-real-ip", "127.0.0.1"}]
    }

    # Test the controller function directly
    Mix.shell().info("Processing the test email...")
    result = ElektrineWeb.HarakaWebhookController.create(conn, params)

    case result do
      %{status: 200} ->
        Mix.shell().info("Test email processed successfully!")

      _ ->
        Mix.shell().error("Failed to process test email: #{inspect(result)}")
    end
  end
end
