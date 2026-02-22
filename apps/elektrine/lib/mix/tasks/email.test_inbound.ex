defmodule Mix.Tasks.Email.TestInbound do
  @moduledoc false
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

    {:ok, mailbox} = Elektrine.Email.ensure_user_has_mailbox(user)
    mailbox
  end

  defp test_inbound_email(mailbox) do
    Mix.shell().info("Testing inbound email processing...")

    # Create a sample raw email
    date = DateTime.utc_now() |> DateTime.to_string()
    message_id = "<test-#{System.system_time(:millisecond)}@example.com>"

    raw_email = """
    From: sender@example.com
    To: #{mailbox.email}
    Subject: Test Email #{DateTime.utc_now()}
    Message-ID: #{message_id}
    Date: #{date}
    MIME-Version: 1.0
    Content-Type: multipart/alternative; boundary="boundary-string"

    --boundary-string
    Content-Type: text/plain; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    This is a test email from the inbound processor.

    --boundary-string
    Content-Type: text/html; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    <html>
    <body>
      <p>This is a <strong>test email</strong> from the inbound processor.</p>
    </body>
    </html>

    --boundary-string--
    """

    # Encode the email in Base64
    base64_message = Base.encode64(raw_email)

    # Make a request to the API endpoint
    url = "http://localhost:4000/api/postal/inbound"
    headers = [{"Content-Type", "application/json"}]
    body = Jason.encode!(%{"message" => base64_message})

    Mix.shell().info("Sending test email to #{url}...")

    # Start HTTP client if not started
    Application.ensure_all_started(:hackney)

    # Make the HTTP request
    case :hackney.post(url, headers, body, [:with_body]) do
      {:ok, 200, _headers, _body} ->
        Mix.shell().info("Test email processed successfully!")
        Mix.shell().info("Check the inbox for an email from 'sender@example.com'")

      {:ok, status, _headers, response_body} ->
        Mix.shell().error("Request failed with status #{status}")
        Mix.shell().error("Response: #{response_body}")

      {:error, reason} ->
        Mix.shell().error("HTTP request failed: #{inspect(reason)}")
    end

    # Alternatively, we can test the controller directly
    Mix.shell().info("\nAlternatively testing the controller directly...")

    # Create a test connection and params
    params = %{"message" => base64_message}

    conn = %Plug.Conn{
      remote_ip: {127, 0, 0, 1},
      req_headers: [{"x-real-ip", "127.0.0.1"}]
    }

    try do
      # Process the email directly
      result = ElektrineWeb.HarakaWebhookController.create(conn, params)

      case result do
        %{status: 200} ->
          Mix.shell().info("Direct controller test succeeded!")

        _ ->
          Mix.shell().error("Direct controller test failed: #{inspect(result)}")
      end
    rescue
      e ->
        Mix.shell().error("Error in direct controller test: #{inspect(e)}")
    end
  end
end
