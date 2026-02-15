defmodule Elektrine.Email.HeaderSanitizer do
  @moduledoc """
  Sanitizes email headers to prevent SMTP header injection attacks.

  SMTP header injection occurs when attackers inject newline characters
  (CRLF sequences) into email headers, allowing them to add additional
  headers or modify the email's behavior.
  """

  require Logger

  @doc """
  Sanitizes all email parameters to prevent SMTP header injection.

  Returns {:ok, sanitized_params} or {:error, reason}.
  """
  def sanitize_email_params(params) do
    try do
      sanitized = %{
        from: sanitize_email_header(params[:from] || params["from"]),
        to: sanitize_email_header(params[:to] || params["to"]),
        cc: sanitize_email_header(params[:cc] || params["cc"]),
        bcc: sanitize_email_header(params[:bcc] || params["bcc"]),
        subject: sanitize_subject_header(params[:subject] || params["subject"]),
        reply_to: sanitize_email_header(params[:reply_to] || params["reply_to"]),
        text_body: params[:text_body] || params["text_body"],
        html_body: params[:html_body] || params["html_body"]
      }

      # Validate that critical fields are present and valid
      case validate_critical_fields(sanitized) do
        :ok -> {:ok, sanitized}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        Logger.error("Error sanitizing email params: #{inspect(e)}")
        {:error, "Invalid email parameters"}
    end
  end

  @doc """
  Sanitizes a single email header field by removing dangerous characters.
  """
  def sanitize_email_header(nil), do: nil
  def sanitize_email_header(""), do: ""

  def sanitize_email_header(header) when is_binary(header) do
    header
    # First ensure valid UTF-8
    |> ensure_valid_utf8()
    # Remove all forms of line breaks that could enable header injection
    |> String.replace(~r/[\r\n\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    # Remove other dangerous Unicode whitespace characters
    |> String.replace(~r/[\x85]/, "")
    # Trim whitespace
    |> String.trim()
    # Limit length to prevent buffer overflow attacks
    |> String.slice(0, 1000)
  end

  # Handle iolists (can occur from MIME header decoding)
  def sanitize_email_header(header) when is_list(header) do
    header
    |> iolist_to_binary_safe()
    |> sanitize_email_header()
  end

  # Catch-all for any other unexpected input
  def sanitize_email_header(_header), do: nil

  # Ensures the binary is valid UTF-8, replacing invalid sequences
  defp ensure_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      # Replace invalid UTF-8 sequences with replacement character or remove them
      binary
      |> :unicode.characters_to_binary(:utf8, :utf8)
      |> case do
        {:error, valid, _rest} -> valid
        {:incomplete, valid, _rest} -> valid
        valid when is_binary(valid) -> valid
      end
      |> ensure_printable()
    end
  end

  defp ensure_printable(binary) do
    for <<byte <- binary>>, byte >= 32 or byte in [?\t, ?\n, ?\r], into: "", do: <<byte>>
  end

  @doc """
  Sanitizes email subject with additional validation for common attacks.
  """
  def sanitize_subject_header(nil), do: ""
  def sanitize_subject_header(""), do: ""

  def sanitize_subject_header(subject) when is_binary(subject) do
    do_sanitize_subject(subject)
  end

  # Handle iolists (can occur from MIME header decoding)
  def sanitize_subject_header(subject) when is_list(subject) do
    subject
    |> iolist_to_binary_safe()
    |> do_sanitize_subject()
  end

  # Catch-all for any other unexpected input - return empty string to be safe
  def sanitize_subject_header(_subject), do: ""

  defp do_sanitize_subject(subject) when is_binary(subject) do
    sanitized = sanitize_email_header(subject)

    # Additional subject-specific validation
    if String.contains?(sanitized, ["bcc:", "cc:", "to:", "from:", "reply-to:"]) do
      # Check for suspicious patterns that might indicate header injection attempts
      Logger.warning(
        "Suspicious header injection attempt detected in subject: #{inspect(subject)}"
      )

      # Strip out the suspicious content
      sanitized
      |> String.replace(~r/(bcc|cc|to|from|reply-to):/i, "")
      |> String.trim()
    else
      # Note: Removed MIME encoded-word truncation check that was breaking international text.
      # MIME encoded-words (=?charset?encoding?text?=) are legitimate per RFC 2047 and used
      # for non-ASCII characters like Chinese, Japanese, etc. The sanitize_email_header/1
      # function already removes newlines and control characters for header injection protection.
      sanitized
    end
  end

  defp do_sanitize_subject(_), do: ""

  # Safely convert an iolist (possibly improper) to a binary
  defp iolist_to_binary_safe(data) do
    try do
      IO.iodata_to_binary(data)
    rescue
      ArgumentError ->
        # Handle improper iolists like [codepoint | binary]
        flatten_iolist(data, [])
        |> IO.iodata_to_binary()
    end
  end

  # Recursively flatten an improper iolist, converting codepoints to binaries
  defp flatten_iolist([], acc), do: Enum.reverse(acc)
  defp flatten_iolist(binary, acc) when is_binary(binary), do: Enum.reverse([binary | acc])

  defp flatten_iolist(int, acc) when is_integer(int) and int >= 0 and int <= 0x10FFFF do
    Enum.reverse([<<int::utf8>> | acc])
  end

  # Skip invalid codepoints
  defp flatten_iolist(int, acc) when is_integer(int), do: acc

  defp flatten_iolist([head | tail], acc) do
    case head do
      h when is_binary(h) ->
        flatten_iolist(tail, [h | acc])

      h when is_integer(h) and h >= 0 and h <= 0x10FFFF ->
        flatten_iolist(tail, [<<h::utf8>> | acc])

      # Skip invalid codepoints
      h when is_integer(h) ->
        flatten_iolist(tail, acc)

      h when is_list(h) ->
        flatten_iolist(tail, Enum.reverse(flatten_iolist(h, []), acc))

      _ ->
        flatten_iolist(tail, acc)
    end
  end

  # Handle improper list tail (e.g., [head | binary])
  defp flatten_iolist(tail, acc) when is_binary(tail), do: Enum.reverse([tail | acc])
  defp flatten_iolist(_, acc), do: Enum.reverse(acc)

  # Validates that critical email fields are present and valid after sanitization.
  defp validate_critical_fields(params) do
    cond do
      is_nil(params.from) or params.from == "" ->
        {:error, "From address is required"}

      is_nil(params.to) or params.to == "" ->
        {:error, "To address is required"}

      contains_header_injection?(params.from) ->
        {:error, "Invalid characters in from address"}

      contains_header_injection?(params.to) ->
        {:error, "Invalid characters in to address"}

      contains_header_injection?(params.cc) ->
        {:error, "Invalid characters in cc address"}

      contains_header_injection?(params.bcc) ->
        {:error, "Invalid characters in bcc address"}

      contains_header_injection?(params.subject) ->
        {:error, "Invalid characters in subject"}

      contains_header_injection?(params.reply_to) ->
        {:error, "Invalid characters in reply-to address"}

      true ->
        :ok
    end
  end

  # Checks if a field still contains characters that could be used for header injection.
  # This is a secondary check after sanitization.
  defp contains_header_injection?(nil), do: false
  defp contains_header_injection?(""), do: false

  defp contains_header_injection?(field) when is_binary(field) do
    # Look for any remaining dangerous patterns
    dangerous_patterns = [
      # Basic CRLF injection
      ~r/[\r\n]/,
      # Control characters
      ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/,
      # Null bytes
      ~r/\x00/,
      # URL-encoded injection attempts
      ~r/\%0A|\%0D|\%00/i,
      # Escaped injection attempts
      ~r/\\r|\\n|\\0/
    ]

    Enum.any?(dangerous_patterns, fn pattern ->
      String.match?(field, pattern)
    end)
  end

  defp contains_header_injection?(_), do: false

  @doc """
  Validates that an email address format is correct and safe.
  """
  def validate_email_format(email) when is_binary(email) do
    # Basic email regex that excludes dangerous characters
    email_regex =
      ~r/^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/

    # RFC 5321 limit
    String.match?(email, email_regex) and
      not contains_header_injection?(email) and
      String.length(email) <= 254
  end

  def validate_email_format(_), do: false

  # Local domains that should not be spoofed by external senders
  @local_domains ["elektrine.com", "z.org"]

  @doc """
  Checks for multiple From headers in raw email data.
  Returns {:ok, :valid} or {:error, reason}.
  """
  def check_multiple_from_headers(nil), do: {:ok, :valid}
  def check_multiple_from_headers(""), do: {:ok, :valid}

  def check_multiple_from_headers(raw_email) when is_binary(raw_email) do
    # Count From: headers (case-insensitive, at start of line)
    from_count =
      raw_email
      |> String.split(~r/\r?\n/)
      |> Enum.count(fn line ->
        String.match?(line, ~r/^From:/i)
      end)

    if from_count > 1 do
      Logger.warning("Multiple From headers detected: #{from_count} found")
      {:error, "Multiple From headers found"}
    else
      {:ok, :valid}
    end
  end

  def check_multiple_from_headers(_), do: {:ok, :valid}

  @doc """
  Checks if an external sender is trying to spoof a local domain.
  `from_address` is the claimed From address.
  `authenticated_user` is the authenticated user (nil if not authenticated).

  Returns {:ok, :valid} or {:error, reason}.
  """
  def check_local_domain_spoofing(from_address, authenticated_user) do
    from_domain = extract_domain(from_address)

    cond do
      # No From address
      is_nil(from_domain) ->
        {:ok, :valid}

      # Not a local domain - allow
      not Enum.member?(@local_domains, String.downcase(from_domain)) ->
        {:ok, :valid}

      # Local domain but user is authenticated - verify they own it
      not is_nil(authenticated_user) ->
        # User is authenticated, they can send from local domains
        {:ok, :valid}

      # Local domain and not authenticated - reject
      true ->
        Logger.warning("Local domain spoofing attempt: #{from_address} (not authenticated)")
        {:error, "Sender domain is a local domain"}
    end
  end

  @doc """
  Validates that the recipient domain exists and has MX records.
  Returns {:ok, :valid} or {:error, reason}.
  """
  def validate_recipient_domain(to_address) when is_binary(to_address) do
    domain = extract_domain(to_address)

    cond do
      is_nil(domain) ->
        {:error, "Invalid recipient address"}

      String.length(domain) > 253 ->
        {:error, "Domain name too long"}

      true ->
        case check_domain_dns(domain) do
          {:ok, :exists} -> {:ok, :valid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def validate_recipient_domain(_), do: {:error, "Invalid recipient address"}

  @doc """
  Checks if an email appears to be a backscatter/bounce attack.
  Bounce attacks send fake bounces to victims using forged return paths.

  Returns {:ok, :valid} or {:error, reason}.
  """
  def check_bounce_attack(params) do
    from = params[:from] || params["from"] || ""
    subject = params[:subject] || params["subject"] || ""
    to = params[:to] || params["to"] || ""

    # Common bounce indicators
    is_bounce =
      String.match?(String.downcase(from), ~r/^(mailer-daemon|postmaster|mail-daemon)@/) or
        String.match?(
          String.downcase(subject),
          ~r/^(undelivered|returned|failure|rejected|bounce)/i
        ) or
        String.contains?(String.downcase(subject), [
          "delivery status",
          "mail delivery failed",
          "undeliverable"
        ])

    if is_bounce do
      # For bounces, verify the original recipient (now in To:) exists in our system
      to_domain = extract_domain(to)

      if to_domain && Enum.member?(@local_domains, String.downcase(to_domain)) do
        # Check if this user actually exists
        to_local = extract_local_part(to)

        if to_local && user_exists?(to_local, to_domain) do
          {:ok, :valid}
        else
          Logger.warning("Suspected bounce attack: bounce to non-existent user #{to}")
          {:error, "Suspected bounce attack"}
        end
      else
        # Bounce to external domain - not our problem
        {:ok, :valid}
      end
    else
      {:ok, :valid}
    end
  end

  # Extracts the domain part from an email address
  defp extract_domain(nil), do: nil
  defp extract_domain(""), do: nil

  defp extract_domain(email) when is_binary(email) do
    # Handle "Display Name <email@domain.com>" format
    clean_email =
      case Regex.run(~r/<([^>]+)>/, email) do
        [_, addr] -> addr
        _ -> email
      end

    case String.split(clean_email, "@") do
      [_, domain] -> String.trim(domain)
      _ -> nil
    end
  end

  defp extract_domain(_), do: nil

  # Extracts the local part from an email address
  defp extract_local_part(nil), do: nil
  defp extract_local_part(""), do: nil

  defp extract_local_part(email) when is_binary(email) do
    clean_email =
      case Regex.run(~r/<([^>]+)>/, email) do
        [_, addr] -> addr
        _ -> email
      end

    case String.split(clean_email, "@") do
      [local, _] -> String.trim(local) |> String.downcase()
      _ -> nil
    end
  end

  defp extract_local_part(_), do: nil

  # Checks if domain has valid DNS records (MX or A record)
  defp check_domain_dns(domain) do
    # First try MX lookup
    case :inet_res.lookup(String.to_charlist(domain), :in, :mx, timeout: 5000) do
      [] ->
        # No MX records, try A record
        case :inet_res.lookup(String.to_charlist(domain), :in, :a, timeout: 5000) do
          [] ->
            # Try AAAA record
            case :inet_res.lookup(String.to_charlist(domain), :in, :aaaa, timeout: 5000) do
              [] ->
                Logger.debug("DNS check failed for domain: #{domain}")
                {:error, "Domain may not exist or DNS check failed"}

              _ ->
                {:ok, :exists}
            end

          _ ->
            {:ok, :exists}
        end

      _ ->
        {:ok, :exists}
    end
  rescue
    e ->
      Logger.warning("DNS lookup error for #{domain}: #{inspect(e)}")
      # On DNS errors, allow the email (fail open for availability)
      {:ok, :exists}
  end

  # Checks if a user exists in our system
  defp user_exists?(local_part, domain) do
    # Check both username and handle
    case Elektrine.Accounts.get_user_by_username_or_handle(local_part) do
      nil ->
        # Also check email aliases
        case Elektrine.Email.Aliases.get_alias_by_email("#{local_part}@#{domain}") do
          nil -> false
          _ -> true
        end

      _ ->
        true
    end
  rescue
    # Fail open on errors
    _ -> true
  end
end
