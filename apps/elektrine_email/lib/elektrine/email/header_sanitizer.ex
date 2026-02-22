defmodule Elektrine.Email.HeaderSanitizer do
  @moduledoc "Sanitizes email headers to prevent SMTP header injection attacks.\n\nSMTP header injection occurs when attackers inject newline characters\n(CRLF sequences) into email headers, allowing them to add additional\nheaders or modify the email's behavior.\n"
  require Logger

  @doc "Sanitizes all email parameters to prevent SMTP header injection.\n\nReturns {:ok, sanitized_params} or {:error, reason}.\n"
  def sanitize_email_params(params) do
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

    case validate_critical_fields(sanitized) do
      :ok -> {:ok, sanitized}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.error("Error sanitizing email params: #{inspect(e)}")
      {:error, "Invalid email parameters"}
  end

  @doc "Sanitizes a single email header field by removing dangerous characters.\n"
  def sanitize_email_header(nil) do
    nil
  end

  def sanitize_email_header("") do
    ""
  end

  def sanitize_email_header(header) when is_binary(header) do
    header
    |> ensure_valid_utf8()
    |> String.replace(~r/[\r\n\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.replace(~r/[\x{0085}]/u, "")
    |> String.trim()
    |> String.slice(0, 1000)
  end

  def sanitize_email_header(header) when is_list(header) do
    header |> iolist_to_binary_safe() |> sanitize_email_header()
  end

  def sanitize_email_header(_header) do
    nil
  end

  defp ensure_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
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
    for <<byte <- binary>>, byte >= 32 or byte in ~c"\t\n\r", into: "", do: <<byte>>
  end

  @doc "Sanitizes email subject with additional validation for common attacks.\n"
  def sanitize_subject_header(nil) do
    ""
  end

  def sanitize_subject_header("") do
    ""
  end

  def sanitize_subject_header(subject) when is_binary(subject) do
    do_sanitize_subject(subject)
  end

  def sanitize_subject_header(subject) when is_list(subject) do
    subject |> iolist_to_binary_safe() |> do_sanitize_subject()
  end

  def sanitize_subject_header(_subject) do
    ""
  end

  defp do_sanitize_subject(subject) when is_binary(subject) do
    sanitized = sanitize_email_header(subject)

    if String.contains?(sanitized, ["bcc:", "cc:", "to:", "from:", "reply-to:"]) do
      Logger.warning(
        "Suspicious header injection attempt detected in subject: #{inspect(subject)}"
      )

      sanitized |> String.replace(~r/(bcc|cc|to|from|reply-to):/i, "") |> String.trim()
    else
      sanitized
    end
  end

  defp do_sanitize_subject(_) do
    ""
  end

  defp iolist_to_binary_safe(data) do
    IO.iodata_to_binary(data)
  rescue
    ArgumentError -> flatten_iolist(data, []) |> IO.iodata_to_binary()
  end

  defp flatten_iolist([], acc) do
    Enum.reverse(acc)
  end

  defp flatten_iolist(binary, acc) when is_binary(binary) do
    Enum.reverse([binary | acc])
  end

  defp flatten_iolist(int, acc) when is_integer(int) and int >= 0 and int <= 1_114_111 do
    Enum.reverse([<<int::utf8>> | acc])
  end

  defp flatten_iolist(int, acc) when is_integer(int) do
    acc
  end

  defp flatten_iolist([head | tail], acc) do
    case head do
      h when is_binary(h) ->
        flatten_iolist(tail, [h | acc])

      h when is_integer(h) and h >= 0 and h <= 1_114_111 ->
        flatten_iolist(tail, [<<h::utf8>> | acc])

      h when is_integer(h) ->
        flatten_iolist(tail, acc)

      h when is_list(h) ->
        flatten_iolist(tail, Enum.reverse(flatten_iolist(h, []), acc))

      _ ->
        flatten_iolist(tail, acc)
    end
  end

  defp flatten_iolist(tail, acc) when is_binary(tail) do
    Enum.reverse([tail | acc])
  end

  defp flatten_iolist(_, acc) do
    Enum.reverse(acc)
  end

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

  defp contains_header_injection?(nil) do
    false
  end

  defp contains_header_injection?("") do
    false
  end

  defp contains_header_injection?(field) when is_binary(field) do
    dangerous_patterns = [
      ~r/[\r\n]/,
      ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/,
      ~r/\x00/,
      ~r/\%0A|\%0D|\%00/i,
      ~r/\\r|\\n|\\0/
    ]

    Enum.any?(dangerous_patterns, fn pattern -> String.match?(field, pattern) end)
  end

  defp contains_header_injection?(_) do
    false
  end

  @doc "Validates that an email address format is correct and safe.\n"
  def validate_email_format(email) when is_binary(email) do
    email_regex =
      ~r/^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/

    String.match?(email, email_regex) and not contains_header_injection?(email) and
      String.length(email) <= 254
  end

  def validate_email_format(_) do
    false
  end

  @local_domains ["elektrine.com", "z.org"]
  @doc "Checks for multiple From headers in raw email data.\nReturns {:ok, :valid} or {:error, reason}.\n"
  def check_multiple_from_headers(nil) do
    {:ok, :valid}
  end

  def check_multiple_from_headers("") do
    {:ok, :valid}
  end

  def check_multiple_from_headers(raw_email) when is_binary(raw_email) do
    from_count =
      raw_email
      |> String.split(~r/\r?\n/)
      |> Enum.count(fn line -> String.match?(line, ~r/^From:/i) end)

    if from_count > 1 do
      Logger.warning("Multiple From headers detected: #{from_count} found")
      {:error, "Multiple From headers found"}
    else
      {:ok, :valid}
    end
  end

  def check_multiple_from_headers(_) do
    {:ok, :valid}
  end

  @doc "Checks if an external sender is trying to spoof a local domain.\n`from_address` is the claimed From address.\n`authenticated_user` is the authenticated user (nil if not authenticated).\n\nReturns {:ok, :valid} or {:error, reason}.\n"
  def check_local_domain_spoofing(from_address, authenticated_user) do
    from_domain = extract_domain(from_address)

    cond do
      is_nil(from_domain) ->
        {:ok, :valid}

      not Enum.member?(@local_domains, String.downcase(from_domain)) ->
        {:ok, :valid}

      not is_nil(authenticated_user) ->
        {:ok, :valid}

      true ->
        Logger.warning("Local domain spoofing attempt: #{from_address} (not authenticated)")
        {:error, "Sender domain is a local domain"}
    end
  end

  @doc "Validates that the recipient domain exists and has MX records.\nReturns {:ok, :valid} or {:error, reason}.\n"
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

  def validate_recipient_domain(_) do
    {:error, "Invalid recipient address"}
  end

  @doc "Checks if an email appears to be a backscatter/bounce attack.\nBounce attacks send fake bounces to victims using forged return paths.\n\nReturns {:ok, :valid} or {:error, reason}.\n"
  def check_bounce_attack(params) do
    from = params[:from] || params["from"] || ""
    subject = params[:subject] || params["subject"] || ""
    to = params[:to] || params["to"] || ""

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
      to_domain = extract_domain(to)

      if to_domain && Enum.member?(@local_domains, String.downcase(to_domain)) do
        to_local = extract_local_part(to)

        if to_local && user_exists?(to_local, to_domain) do
          {:ok, :valid}
        else
          Logger.warning("Suspected bounce attack: bounce to non-existent user #{to}")
          {:error, "Suspected bounce attack"}
        end
      else
        {:ok, :valid}
      end
    else
      {:ok, :valid}
    end
  end

  defp extract_domain(nil) do
    nil
  end

  defp extract_domain("") do
    nil
  end

  defp extract_domain(email) when is_binary(email) do
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

  defp extract_domain(_) do
    nil
  end

  defp extract_local_part(nil) do
    nil
  end

  defp extract_local_part("") do
    nil
  end

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

  defp extract_local_part(_) do
    nil
  end

  defp check_domain_dns(domain) do
    case :inet_res.lookup(String.to_charlist(domain), :in, :mx, timeout: 5000) do
      [] ->
        case :inet_res.lookup(String.to_charlist(domain), :in, :a, timeout: 5000) do
          [] ->
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
      {:ok, :exists}
  end

  defp user_exists?(local_part, domain) do
    case Elektrine.Accounts.get_user_by_username_or_handle(local_part) do
      nil ->
        case Elektrine.Email.Aliases.get_alias_by_email("#{local_part}@#{domain}") do
          nil -> false
          _ -> true
        end

      _ ->
        true
    end
  rescue
    _ -> true
  end
end
