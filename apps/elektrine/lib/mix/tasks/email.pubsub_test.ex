defmodule Mix.Tasks.Email.PubsubTest do
  use Mix.Task
  require Logger

  @shortdoc "Test PubSub email broadcasting"
  def run([user_id]) do
    Mix.Task.run("app.start")

    # Create a test email message
    test_message = %{
      id: "test-#{System.unique_integer([:positive])}",
      message_id: "test-message-#{System.unique_integer([:positive])}@example.com",
      subject: "Test PubSub Email",
      from: "test@example.com",
      to: ["user@example.com"],
      html_body: "<p>This is a test email for PubSub</p>",
      plain_body: "This is a test email for PubSub",
      read: false,
      inserted_at: DateTime.utc_now()
    }

    Logger.info("Broadcasting test email to user:#{user_id}")

    # Broadcast the test message
    Phoenix.PubSub.broadcast!(
      Elektrine.PubSub,
      "user:#{user_id}",
      {:new_email, test_message}
    )

    Logger.info("Test email broadcast complete!")
  end
end
