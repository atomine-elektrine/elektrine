defmodule Elektrine.MailAuth.RateLimiter do
  @moduledoc """
  Cross-protocol rate limiter for mailbox authentication by account identifier.

  This complements per-IP rate limiting by also throttling repeated failures
  against the same account name (or email address), reducing account-targeted
  password spray attacks.
  """

  use Elektrine.RateLimiter,
    table: :mail_auth_account_rate_limiter,
    limits: [
      {:minute, 6},
      {:hour, 30}
    ],
    lockout: {:minutes, 20},
    cleanup_interval: {:minutes, 1}

  @spec check_attempt(atom(), String.t() | nil) :: {:ok, non_neg_integer()} | {:error, atom()}
  def check_attempt(protocol, identifier) do
    key = normalized_key(protocol, identifier)

    case check_rate_limit(key) do
      {:ok, :allowed} ->
        status = get_status(key)
        remaining = get_in(status.attempts, [60, :remaining]) || 0
        {:ok, remaining}

      {:error, {:rate_limited, _retry_after, :locked_out}} ->
        {:error, :blocked}

      {:error, {:rate_limited, _retry_after, _reason}} ->
        {:error, :rate_limited}
    end
  end

  @spec record_failure(atom(), String.t() | nil) :: :ok
  def record_failure(protocol, identifier) do
    record_attempt(normalized_key(protocol, identifier))
  end

  @spec clear_attempts(atom(), String.t() | nil) :: :ok
  def clear_attempts(protocol, identifier) do
    clear_limits(normalized_key(protocol, identifier))
  end

  @spec failure_count(atom(), String.t() | nil) :: non_neg_integer()
  def failure_count(protocol, identifier) do
    key = normalized_key(protocol, identifier)
    status = get_status(key)
    get_in(status.attempts, [60, :count]) || 0
  end

  @doc """
  Returns a stable key with a hashed identifier so account names are not stored
  in plain text in ETS.
  """
  @spec normalized_key(atom(), String.t() | nil) :: String.t()
  def normalized_key(protocol, identifier) do
    normalized_protocol = normalize_protocol(protocol)
    normalized_identifier = normalize_identifier(identifier)
    digest = :crypto.hash(:sha256, normalized_identifier) |> Base.encode16(case: :lower)
    "#{normalized_protocol}:#{digest}"
  end

  defp normalize_protocol(protocol) when protocol in [:imap, :pop3, :smtp], do: protocol

  defp normalize_protocol(protocol) when is_binary(protocol) do
    case String.downcase(protocol) do
      "imap" -> :imap
      "pop3" -> :pop3
      "smtp" -> :smtp
      _ -> :unknown
    end
  end

  defp normalize_protocol(_protocol), do: :unknown

  defp normalize_identifier(nil), do: "__nil__"

  defp normalize_identifier(identifier) do
    identifier
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "__empty__"
      value -> value
    end
  end
end
