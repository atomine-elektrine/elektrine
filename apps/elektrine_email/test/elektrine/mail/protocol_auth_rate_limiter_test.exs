defmodule Elektrine.Mail.ProtocolAuthRateLimiterTest do
  use ExUnit.Case, async: false

  alias Elektrine.IMAP.RateLimiter, as: IMAPRateLimiter
  alias Elektrine.POP3.RateLimiter, as: POP3RateLimiter
  alias Elektrine.SMTP.RateLimiter, as: SMTPRateLimiter

  test "SMTP allows a realistic client setup retry burst" do
    key = unique_key("smtp")
    on_exit(fn -> SMTPRateLimiter.clear_attempts(key) end)

    Enum.each(1..7, fn _ -> :ok = SMTPRateLimiter.record_failure(key) end)

    assert {:ok, 1} = SMTPRateLimiter.check_attempt(key)

    :ok = SMTPRateLimiter.record_failure(key)
    assert {:error, :blocked} = SMTPRateLimiter.check_attempt(key)
  end

  test "POP3 allows ten attempts per minute" do
    key = unique_key("pop3")
    on_exit(fn -> POP3RateLimiter.clear_attempts(key) end)

    Enum.each(1..9, fn _ -> :ok = POP3RateLimiter.record_failure(key) end)

    assert {:ok, 1} = POP3RateLimiter.check_attempt(key)

    :ok = POP3RateLimiter.record_failure(key)
    assert {:error, :blocked} = POP3RateLimiter.check_attempt(key)
  end

  test "IMAP allows twenty attempts per minute" do
    key = unique_key("imap")
    on_exit(fn -> IMAPRateLimiter.clear_attempts(key) end)

    Enum.each(1..19, fn _ -> :ok = IMAPRateLimiter.record_failure(key) end)

    assert {:ok, 1} = IMAPRateLimiter.check_attempt(key)

    :ok = IMAPRateLimiter.record_failure(key)
    assert {:error, :blocked} = IMAPRateLimiter.check_attempt(key)
  end

  defp unique_key(protocol),
    do: "#{protocol}-setup-#{System.unique_integer([:positive])}"
end
