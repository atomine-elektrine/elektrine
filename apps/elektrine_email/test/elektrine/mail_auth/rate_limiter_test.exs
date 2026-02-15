defmodule Elektrine.MailAuth.RateLimiterTest do
  use ExUnit.Case, async: false

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

  test "rate limiting is protocol-specific per identifier", %{identifier: identifier} do
    Enum.each(1..6, fn _ ->
      :ok = RateLimiter.record_failure(:imap, identifier)
    end)

    assert {:error, :blocked} = RateLimiter.check_attempt(:imap, identifier)
    assert {:ok, _remaining} = RateLimiter.check_attempt(:smtp, identifier)
  end
end
