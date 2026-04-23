defmodule Elektrine.MailAuth.RateLimiterTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.Accounts
  alias Elektrine.Email
  alias Elektrine.MailAuth.RateLimiter

  setup do
    identifier = "mail-auth-#{System.unique_integer([:positive])}@example.com"
    RateLimiter.clear_attempts(:imap, identifier)
    RateLimiter.clear_attempts(:pop3, identifier)
    RateLimiter.clear_attempts(:smtp, identifier)

    on_exit(fn ->
      RateLimiter.clear_attempts(:imap, identifier)
      RateLimiter.clear_attempts(:pop3, identifier)
      RateLimiter.clear_attempts(:smtp, identifier)
    end)

    %{identifier: identifier}
  end

  test "locks an identifier after repeated failures", %{identifier: identifier} do
    Enum.each(1..6, fn _ ->
      :ok = RateLimiter.record_failure(:imap, identifier)
    end)

    assert {:error, :blocked} = RateLimiter.check_attempt(:imap, identifier)
  end

  test "rate limiting applies across imap, pop3, and smtp for the same identifier", %{
    identifier: identifier
  } do
    Enum.each(1..6, fn _ ->
      :ok = RateLimiter.record_failure(:imap, identifier)
    end)

    assert {:error, :blocked} = RateLimiter.check_attempt(:imap, identifier)
    assert {:error, :blocked} = RateLimiter.check_attempt(:pop3, identifier)
    assert {:error, :blocked} = RateLimiter.check_attempt(:smtp, identifier)
  end

  test "username and mailbox email resolve to the same account subject" do
    username = "mailauth#{System.unique_integer([:positive])}"

    {:ok, user} =
      Accounts.create_user(%{
        username: username,
        password: "MailAuthPass123!",
        password_confirmation: "MailAuthPass123!"
      })

    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

    on_exit(fn ->
      RateLimiter.clear_attempts(:imap, username)
      RateLimiter.clear_attempts(:smtp, mailbox.email)
    end)

    Enum.each(1..6, fn _ ->
      :ok = RateLimiter.record_failure(:imap, username)
    end)

    assert {:error, :blocked} = RateLimiter.check_attempt(:smtp, mailbox.email)
    assert Accounts.mail_auth_subject(username) == Accounts.mail_auth_subject(mailbox.email)
  end
end
