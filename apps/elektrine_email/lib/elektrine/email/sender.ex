defmodule Elektrine.Email.Sender do
  @moduledoc """
  Handles email sending functionality.

  ## Error Types

  This module returns standardized error tuples:

  - `{:error, :rate_limit_exceeded}` - User exceeded daily/hourly/minute email limit
  - `{:error, :no_mailbox}` - User doesn't have a mailbox
  - `{:error, :unauthorized_from_address}` - User doesn't own the from address
  - `{:error, :forward_to_external}` - Internal email needs external forwarding
  - `{:error, :forward_target_not_found}` - Forwarding target couldn't be resolved
  - `{:error, :no_mailbox}` - Recipient mailbox not found
  - `{:error, :recipient_not_found}` - Recipient doesn't exist
  - `{:error, :forwarding_loop_detected}` - Circular forwarding detected
  - `{:error, :storage_limit_exceeded}` - User storage limit exceeded
  - `{:error, string}` - Validation error with descriptive message
  """

  alias Elektrine.Email
  alias Elektrine.Email.Mailbox
  alias Elektrine.Email.RateLimiter
  alias Elektrine.Email.Sanitizer
  alias Elektrine.Email.HeaderDecoder
  alias Elektrine.Email.HeaderSanitizer
  alias Elektrine.Email.Unsubscribes
  alias Elektrine.Email.ListTypes
  alias Elektrine.Email.PGP
  alias Elektrine.Telemetry.Events
  alias Elektrine.Mailer
  alias Elektrine.Repo
  import Swoosh.Email

  require Logger

  @doc """
  Sends an email from a user's mailbox.

  ## Parameters

    * `user_id` - The ID of the user sending the email
    * `params` - Map containing the email parameters:
      * `:from` - Sender's email address (should be one of the user's mailboxes)
      * `:reply_to` - Reply-to email address (optional, defaults to from address)
      * `:to` - Recipient email address(es) (comma separated string or list)
      * `:cc` - CC recipients (optional)
      * `:bcc` - BCC recipients (optional)
      * `:subject` - Email subject
      * `:text_body` - Plain text body
      * `:html_body` - HTML body (optional)
    * `db_attachments` - Optional map of attachments for DB storage (with S3 metadata, no data field)

  ## Returns

    * `{:ok, message}` - If the email was sent successfully
    * `{:error, reason}` - If there was an error
  """
  def send_email(user_id, params, db_attachments \\ nil) do
    started_at = System.monotonic_time(:millisecond)

    to_emails = parse_email_list(params[:to] || params["to"] || "")
    cc_emails = parse_email_list(params[:cc] || params["cc"] || "")
    bcc_emails = parse_email_list(params[:bcc] || params["bcc"] || "")

    # Check if we have any valid recipients
    all_recipients = to_emails ++ cc_emails ++ bcc_emails

    # Validate recipients first
    result =
      case validate_recipients(all_recipients) do
        {:error, reason} ->
          {:error, reason}

        :ok ->
          # Only check unsubscribes if this is a mass email with an explicit list_id
          # Personal emails (SMTP/webmail without list_id) skip this check
          list_id = params[:list_id]

          if list_id && !is_transactional_email?(list_id) do
            # Mass email - filter out unsubscribed recipients
            case filter_unsubscribed_recipients(to_emails, cc_emails, bcc_emails, list_id) do
              {:error, :all_unsubscribed} ->
                {:error, "All recipients have unsubscribed from this mailing list"}

              {:ok, filtered_to, filtered_cc, filtered_bcc} ->
                # Update params with filtered recipients
                params =
                  params
                  |> Map.put(
                    :to,
                    if(filtered_to != [], do: Enum.join(filtered_to, ", "), else: "")
                  )
                  |> Map.put(
                    :cc,
                    if(filtered_cc != [], do: Enum.join(filtered_cc, ", "), else: "")
                  )
                  |> Map.put(
                    :bcc,
                    if(filtered_bcc != [], do: Enum.join(filtered_bcc, ", "), else: "")
                  )

                continue_send_email(user_id, params, db_attachments)
            end
          else
            # Personal email (no list_id) or transactional - proceed without filtering
            continue_send_email(user_id, params, db_attachments)
          end
      end

    emit_outbound_telemetry(:request, result, started_at, %{route: :auto})
    result
  end

  # Continue with the actual sending logic
  defp continue_send_email(user_id, params, db_attachments) do
    started_at = System.monotonic_time(:millisecond)

    # Canonical outbound boundary:
    # 1) Parse raw SMTP payload (if present) into structured fields.
    # 2) Sanitize once for all downstream routes (internal + external).
    prepared_params = prepare_outbound_payload(params)

    to_emails = parse_email_list(prepared_params[:to] || prepared_params["to"] || "")
    cc_emails = parse_email_list(prepared_params[:cc] || prepared_params["cc"] || "")
    bcc_emails = parse_email_list(prepared_params[:bcc] || prepared_params["bcc"] || "")
    all_recipients = to_emails ++ cc_emails ++ bcc_emails

    # Resolve all recipients once and build a cache map to avoid duplicate DB calls
    resolution_cache = build_resolution_cache(all_recipients)

    # Determine routing strategy: internal or external
    # Email is internal ONLY if:
    # 1. All TO recipients are our domains (elektrine.com, z.org)
    # 2. None of the TO recipients have external forwarding
    routing_strategy = determine_routing_strategy(to_emails, resolution_cache)

    result =
      case routing_strategy do
        :internal ->
          # Handle internal email directly within Phoenix
          # Note: Internal emails never get unsubscribe headers (personal communication)
          send_internal_email(user_id, prepared_params, db_attachments)

        :external ->
          # Send external email via Swoosh
          with {:ok, _remaining} <- RateLimiter.check_rate_limit(user_id),
               {:ok, _recipient_check} <- check_recipient_limits(user_id, prepared_params),
               {:ok, {mailbox, user}} <- get_user_mailbox_with_user(user_id),
               {:ok, _ownership} <-
                 validate_from_address_ownership(prepared_params[:from], user_id),
               {:ok, formatted_params} <- format_from_header(prepared_params, user, mailbox),
               {:ok, resolved_params} <- resolve_recipient_aliases(formatted_params),
               :ok <- validate_external_recipient_domains(resolved_params),
               # Try PGP encryption if recipient has a public key
               pgp_params <- maybe_pgp_encrypt(resolved_params, user_id),
               {:ok, swoosh_response} <- send_via_swoosh(pgp_params) do
            # Always store sent message regardless of source (webmail or SMTP)
            # Mobile clients and many email clients don't append to Sent via IMAP
            case store_sent_message_external(
                   mailbox.id,
                   formatted_params,
                   swoosh_response,
                   db_attachments
                 ) do
              {:ok, _sent_message} ->
                :ok

              {:error, reason} ->
                Logger.error("Failed to store sent message: #{inspect(reason)}")
            end

            # Also deliver to any internal CC/BCC recipients
            deliver_to_internal_cc_bcc_recipients(mailbox.id, formatted_params, db_attachments)

            # Record successful send for rate limiting
            RateLimiter.record_send(user_id)

            # Record recipients for recipient limiting
            record_recipients(user_id, formatted_params)

            {:ok, %{message_id: swoosh_response.message_id, status: "sent"}}
          else
            {:error, :daily_limit_exceeded} ->
              Logger.warning("User #{user_id} exceeded daily email limit")
              {:error, :rate_limit_exceeded}

            {:error, :hourly_limit_exceeded} ->
              Logger.warning("User #{user_id} exceeded hourly email limit")
              {:error, :rate_limit_exceeded}

            {:error, :minute_limit_exceeded} ->
              Logger.warning("User #{user_id} exceeded per-minute email limit")
              {:error, :rate_limit_exceeded}

            {:error, :recipient_limit_exceeded} ->
              Logger.warning("User #{user_id} exceeded unique recipient limit")
              {:error, :recipient_limit_exceeded}

            {:error, reason} ->
              {:error, reason}
          end
      end

    emit_outbound_telemetry(:delivery, result, started_at, %{route: routing_strategy})
    result
  end

  defp prepare_outbound_payload(params) do
    params
    |> parse_raw_email_if_present()
    |> Sanitizer.sanitize_outgoing_email()
  end

  # Check recipient limits for all To, CC, BCC addresses
  defp check_recipient_limits(user_id, params) do
    all_recipients = extract_all_recipients(params)

    # Check each recipient against the limit
    result =
      Enum.reduce_while(all_recipients, {:ok, :allowed}, fn recipient, _acc ->
        case RateLimiter.check_recipient_limit(user_id, recipient) do
          {:ok, :allowed} -> {:cont, {:ok, :allowed}}
          {:error, :recipient_limit_exceeded} -> {:halt, {:error, :recipient_limit_exceeded}}
        end
      end)

    result
  end

  # Extract all recipient emails from params
  defp extract_all_recipients(params) do
    to = normalize_recipients(params[:to])
    cc = normalize_recipients(params[:cc])
    bcc = normalize_recipients(params[:bcc])

    (to ++ cc ++ bcc)
    |> Enum.uniq()
  end

  # Normalize recipients to list of email strings
  defp normalize_recipients(nil), do: []

  defp normalize_recipients(recipients) when is_list(recipients) do
    Enum.map(recipients, fn
      {_name, email} -> String.downcase(email)
      email when is_binary(email) -> String.downcase(email)
    end)
  end

  defp normalize_recipients({_name, email}), do: [String.downcase(email)]
  defp normalize_recipients(email) when is_binary(email), do: [String.downcase(email)]

  # Record all recipients after successful send
  defp record_recipients(user_id, params) do
    all_recipients = extract_all_recipients(params)

    Enum.each(all_recipients, fn recipient ->
      RateLimiter.record_recipient(user_id, recipient)
    end)
  end

  # Parse raw SMTP email data if present using Mail library
  defp parse_raw_email_if_present(params) do
    raw_email = params[:raw_email] || params["raw_email"]

    if raw_email && is_binary(raw_email) && byte_size(raw_email) > 0 do
      # Validate the raw email has basic RFC2822 structure (headers + blank line + body)
      # Headers must be present and separated from body by \r\n\r\n or \n\n
      has_valid_structure =
        String.contains?(raw_email, "\r\n\r\n") || String.contains?(raw_email, "\n\n")

      if has_valid_structure do
        try do
          # Parse email using Mail library for robust RFC2822 parsing
          message = Mail.Parsers.RFC2822.parse(raw_email)

          # Extract subject - try direct extraction first to avoid Mail library encoding issues
          raw_subject_line = extract_raw_subject_from_email(raw_email)

          # Also get Mail library's version for comparison
          mail_subj = Mail.Message.get_header(message, :subject)

          # Use direct extraction if available, otherwise fall back to Mail library
          # This avoids Mail library's potential encoding corruption
          subject =
            cond do
              raw_subject_line && raw_subject_line != "" ->
                HeaderDecoder.decode_mime_header(raw_subject_line)

              mail_subj ->
                HeaderDecoder.decode_mime_header(mail_subj)

              true ->
                "(No Subject)"
            end

          # Extract text and HTML bodies using Mail library
          text_body =
            case Mail.get_text(message) do
              %Mail.Message{body: body} -> body
              _ -> nil
            end

          html_body =
            case Mail.get_html(message) do
              %Mail.Message{body: body} -> body
              _ -> nil
            end

          # Extract attachments
          attachments = Elektrine.IMAP.Commands.extract_attachments(nil, nil, message)

          # IMPORTANT: Delete raw_email after parsing so Haraka client uses the parsed
          # components with proper RFC 2047 encoding instead of sending raw_base64
          params
          |> Map.delete(:raw_email)
          |> Map.delete("raw_email")
          |> Map.put(:subject, subject)
          |> Map.put(:text_body, text_body)
          |> Map.put(:html_body, html_body)
          |> Map.put(:attachments, attachments)
        rescue
          e ->
            Logger.warning(
              "SMTP: Mail library parse failed: #{Exception.message(e)}, using manual extraction"
            )

            # Fall back to manual extraction when Mail library fails
            extract_email_manually(params, raw_email)
        end
      else
        Logger.warning("SMTP: Raw email missing header/body separator, using manual extraction")
        extract_email_manually(params, raw_email)
      end
    else
      params
    end
  end

  # Manual extraction when Mail library fails
  defp extract_email_manually(params, raw_email) do
    # Try to extract subject directly from headers
    subject =
      case extract_raw_subject_from_email(raw_email) do
        subj when is_binary(subj) and subj != "" ->
          HeaderDecoder.decode_mime_header(subj)

        _ ->
          params[:subject] || params["subject"] || "(No Subject)"
      end

    # Try to extract body - split on first blank line
    body =
      case String.split(raw_email, ~r/\r?\n\r?\n/, parts: 2) do
        [_headers, body_part] -> String.trim(body_part)
        _ -> nil
      end

    params
    |> Map.delete(:raw_email)
    |> Map.delete("raw_email")
    |> Map.put(:subject, subject)
    |> Map.put(:text_body, body || params[:text_body] || params["text_body"])
  end

  # Extract raw Subject line from email data for debugging
  defp extract_raw_subject_from_email(raw_email) when is_binary(raw_email) do
    # Find Subject: header line in raw email
    case Regex.run(~r/^Subject:\s*(.+?)(?:\r?\n(?!\s)|\r?\n\r?\n)/ms, raw_email) do
      [_, subject] ->
        # Handle folded headers (continuation lines starting with whitespace)
        subject
        |> String.replace(~r/\r?\n\s+/, " ")
        |> String.trim()

      _ ->
        nil
    end
  end

  # Gets the user's mailbox along with user information
  defp get_user_mailbox_with_user(user_id) do
    import Ecto.Query
    alias Elektrine.Accounts.User

    result =
      Mailbox
      |> where(user_id: ^user_id)
      |> join(:inner, [m], u in User, on: m.user_id == u.id)
      |> select([m, u], {m, u})
      |> Repo.one()

    case result do
      nil ->
        Logger.error("User #{user_id} does not have a mailbox")
        {:error, :no_mailbox}

      {mailbox, user} ->
        {:ok, {mailbox, user}}
    end
  end

  # Formats the From header with display name if available
  defp format_from_header(params, user, mailbox) do
    email_address = params[:from]

    # Check if sending from main mailbox addresses
    main_addresses = [
      mailbox.email,
      String.replace(mailbox.email, "@elektrine.com", "@z.org")
    ]

    formatted_from =
      if user.display_name && String.trim(user.display_name) != "" &&
           email_address in main_addresses do
        # Only add display name for main addresses, not aliases
        display_name = String.trim(user.display_name)
        # Always quote display names for maximum compatibility with email services
        # Escape any existing quotes in the display name
        escaped_name = String.replace(display_name, "\"", "\\\"")
        "\"#{escaped_name}\" <#{email_address}>"
      else
        # For aliases or if no display name, use the email address as-is
        email_address
      end

    updated_params = Map.put(params, :from, formatted_from)
    {:ok, updated_params}
  end

  # Adds RFC 8058 unsubscribe headers to email params
  # Only adds headers if list_id is explicitly provided (i.e., this is a mass/marketing email)
  defp add_unsubscribe_headers(params) do
    # Only add unsubscribe headers if this is a mass email with an explicit list_id
    # Personal emails sent via SMTP/webmail should NOT have list_id set
    list_id = params[:list_id]

    if list_id do
      # Extract recipient email(s)
      recipients = parse_email_list(params[:to] || "")

      # Generate headers for the first recipient
      case recipients do
        [first_recipient | _] ->
          # Generate unsubscribe token
          token = Unsubscribes.generate_token(first_recipient, list_id)

          # Build unsubscribe URLs
          base_url = ElektrineWeb.Endpoint.url()
          unsubscribe_url = "#{base_url}/unsubscribe/#{token}"

          # RFC 8058 headers
          unsubscribe_headers = %{
            "List-Unsubscribe" => "<#{unsubscribe_url}>",
            "List-Unsubscribe-Post" => "List-Unsubscribe=One-Click",
            "List-Id" => "<#{list_id}.elektrine.com>"
          }

          # Merge with existing headers
          existing_headers = params[:headers] || %{}
          updated_headers = Map.merge(existing_headers, unsubscribe_headers)

          Map.put(params, :headers, updated_headers)

        [] ->
          # No recipients, return params unchanged
          params
      end
    else
      # No list_id - this is a personal email, don't add unsubscribe headers
      params
    end
  end

  # Sends the email via external API or Swoosh
  defp send_via_swoosh(params) do
    # Add X-Elektrine-Forwarded header to track forwarding and prevent loops
    params_with_header =
      if params[:forwarded_from] do
        # Already has forwarding info, append to it
        existing = params[:forwarded_from] || ""
        updated = if existing == "", do: params[:to], else: "#{existing}, #{params[:to]}"
        Map.put(params, :forwarded_from, updated)
      else
        params
      end

    # Add unsubscribe headers (RFC 8058)
    params_with_unsubscribe = add_unsubscribe_headers(params_with_header)

    # Try external email service APIs first if not in test/local mode
    if should_use_external_api?() do
      send_via_external_api(params_with_unsubscribe)
    else
      send_via_swoosh_adapter(params_with_unsubscribe)
    end
  end

  defp should_use_external_api? do
    # Use external API unless we're explicitly using local email
    System.get_env("USE_LOCAL_EMAIL") != "true" &&
      Application.get_env(:elektrine, :env) != :test
  end

  defp send_via_external_api(params) do
    # Use Haraka for all email sending
    send_via_haraka_api(params)
  end

  defp send_via_haraka_api(params) do
    started_at = System.monotonic_time(:millisecond)

    result =
      case Elektrine.Email.HarakaClient.send_email(params) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          Logger.error("Haraka API failed: #{inspect(reason)}")
          {:error, reason}
      end

    emit_outbound_telemetry(:provider, result, started_at, %{route: :haraka})
    result
  end

  # Original Swoosh sending logic
  defp send_via_swoosh_adapter(params) do
    started_at = System.monotonic_time(:millisecond)

    try do
      email =
        new()
        |> from(params[:from])
        |> to(parse_recipients(params[:to]))
        |> subject(params[:subject])
        |> text_body(params[:text_body])

      # Add Reply-To if provided
      email =
        if params[:reply_to] && String.trim(params[:reply_to]) != "" do
          reply_to(email, params[:reply_to])
        else
          email
        end

      # Add CC if provided
      email =
        if params[:cc] && String.trim(params[:cc]) != "" do
          cc(email, parse_recipients(params[:cc]))
        else
          email
        end

      # Add BCC if provided  
      email =
        if params[:bcc] && String.trim(params[:bcc]) != "" do
          bcc(email, parse_recipients(params[:bcc]))
        else
          email
        end

      # Add HTML body if provided
      email =
        if params[:html_body] do
          html_body(email, params[:html_body])
        else
          email
        end

      # Add In-Reply-To header for threading
      email =
        if params[:in_reply_to] do
          header(email, "In-Reply-To", params[:in_reply_to])
        else
          email
        end

      # Add custom headers (including unsubscribe headers)
      email =
        if params[:headers] && is_map(params[:headers]) do
          Enum.reduce(params[:headers], email, fn {key, value}, acc ->
            header(acc, key, value)
          end)
        else
          email
        end

      result =
        case Mailer.deliver(email) do
          {:ok, result} ->
            # Generate a message ID for tracking
            message_id = "swoosh-#{:rand.uniform(1_000_000)}-#{System.system_time(:millisecond)}"
            {:ok, %{id: result.id || message_id, message_id: message_id}}

          {:error, reason} ->
            Logger.error("Failed to send email via Swoosh: #{inspect(reason)}")
            {:error, reason}
        end

      emit_outbound_telemetry(:provider, result, started_at, %{route: :swoosh})
      result
    rescue
      e ->
        Logger.error("Error sending email: #{inspect(e)}")
        result = {:error, e}
        emit_outbound_telemetry(:provider, result, started_at, %{route: :swoosh})
        result
    end
  end

  defp emit_outbound_telemetry(stage, result, started_at, metadata) do
    duration = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, _} ->
        Events.email_outbound(stage, :success, duration, metadata)

      {:error, reason} ->
        Events.email_outbound(stage, :failure, duration, Map.put(metadata, :reason, reason))

      _other ->
        Events.email_outbound(stage, :failure, duration, Map.put(metadata, :reason, :unexpected))
    end
  end

  # Stores the sent message in the database
  # Parse recipients from comma-separated string or return as-is if already a list
  defp parse_recipients(nil), do: nil
  defp parse_recipients(recipients) when is_list(recipients), do: recipients

  defp parse_recipients(recipients) when is_binary(recipients) do
    recipients
    |> String.split(~r/[,;]\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      [single] -> single
      multiple -> multiple
    end
  end

  # Parse email list from string or list
  defp parse_email_list(nil), do: []
  defp parse_email_list(""), do: []

  defp parse_email_list(emails) when is_binary(emails) do
    emails
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_email_list(emails) when is_list(emails), do: emails

  # Check if email is internal (between our domains)
  defp is_internal_email?(to_emails) when is_list(to_emails) do
    our_domains = ["elektrine.com", "z.org"]

    Enum.all?(to_emails, fn email ->
      case String.split(String.trim(email), "@") do
        [_local, domain] -> String.downcase(domain) in our_domains
        _ -> false
      end
    end)
  end

  # Build a cache map of all recipient resolutions to avoid duplicate DB calls
  # Returns a map: %{email => {resolved_email, is_external}}
  defp build_resolution_cache(emails) when is_list(emails) do
    emails
    |> Enum.map(fn email ->
      clean = String.trim(String.downcase(email))
      {clean, resolve_single_email(email)}
    end)
    |> Map.new()
  end

  # Determine routing strategy based on TO recipients and forwarding
  # Returns :internal or :external
  defp determine_routing_strategy(to_emails, resolution_cache) do
    # Check if all TO recipients are internal domains
    all_internal = is_internal_email?(to_emails)

    # Check if any TO recipients have external forwarding (using cache)
    has_external_forwarding =
      Enum.any?(to_emails, fn email ->
        case Map.get(resolution_cache, String.trim(String.downcase(email))) do
          {_resolved, is_external} -> is_external
          _ -> false
        end
      end)

    if all_internal && !has_external_forwarding do
      :internal
    else
      :external
    end
  end

  # Resolve all recipient aliases before sending
  defp resolve_recipient_aliases(params) do
    to_resolved = resolve_email_list(parse_email_list(params[:to] || ""))
    cc_resolved = resolve_email_list(parse_email_list(params[:cc] || ""))
    bcc_resolved = resolve_email_list(parse_email_list(params[:bcc] || ""))

    resolved_params =
      params
      |> Map.put(:to, if(to_resolved != [], do: Enum.join(to_resolved, ", "), else: params[:to]))
      |> Map.put(:cc, if(cc_resolved != [], do: Enum.join(cc_resolved, ", "), else: params[:cc]))
      |> Map.put(
        :bcc,
        if(bcc_resolved != [], do: Enum.join(bcc_resolved, ", "), else: params[:bcc])
      )

    {:ok, resolved_params}
  end

  # Resolve a list of email addresses through alias and mailbox forwarding
  # Returns a list of resolved email addresses
  defp resolve_email_list([]), do: []

  defp resolve_email_list(emails) when is_list(emails) do
    Enum.map(emails, fn email ->
      {resolved, _is_external} = resolve_single_email(email)
      resolved
    end)
  end

  # Resolve a single email address and return {resolved_email, is_external}
  defp resolve_single_email(email) do
    clean_email = String.trim(String.downcase(email))

    # Check alias forwarding first
    case Email.resolve_alias(clean_email) do
      target_email when is_binary(target_email) ->
        is_external = !is_internal_email?([target_email])
        {target_email, is_external}

      _ ->
        # Check mailbox forwarding
        case Email.get_mailbox_by_email(clean_email) do
          %Mailbox{forward_enabled: true, forward_to: forward_to}
          when is_binary(forward_to) and forward_to != "" ->
            is_external = !is_internal_email?([forward_to])
            {forward_to, is_external}

          _ ->
            # No forwarding
            {email, false}
        end
    end
  end

  # Validates that the user owns the from address (mailbox or alias)
  defp validate_from_address_ownership(from_address, user_id) do
    case Email.verify_email_ownership(from_address, user_id) do
      {:ok, ownership_type} ->
        {:ok, ownership_type}

      {:error, reason} ->
        Logger.warning(
          "User #{user_id} attempted to send from unauthorized address #{from_address}: #{inspect(reason)}"
        )

        {:error, :unauthorized_from_address}
    end
  end

  # Validates that external recipient domains have valid DNS records
  # This helps prevent bounces and improves deliverability reputation
  defp validate_external_recipient_domains(params) do
    to_emails = parse_email_list(params[:to] || "")
    cc_emails = parse_email_list(params[:cc] || "")
    bcc_emails = parse_email_list(params[:bcc] || "")

    # Only validate external recipients (not our domains)
    our_domains = ["elektrine.com", "z.org"]

    external_recipients =
      (to_emails ++ cc_emails ++ bcc_emails)
      |> Enum.filter(fn email ->
        case String.split(String.trim(email), "@") do
          [_local, domain] -> String.downcase(domain) not in our_domains
          _ -> false
        end
      end)

    # Validate DNS for each external recipient
    invalid_recipients =
      Enum.filter(external_recipients, fn email ->
        case HeaderSanitizer.validate_recipient_domain(email) do
          {:ok, :valid} -> false
          {:error, _reason} -> true
        end
      end)

    case invalid_recipients do
      [] ->
        :ok

      [single] ->
        Logger.warning("DNS validation failed for recipient: #{single}")
        {:error, "Invalid recipient domain: #{single}"}

      multiple ->
        Logger.warning("DNS validation failed for recipients: #{inspect(multiple)}")
        {:error, "Invalid recipient domains detected"}
    end
  end

  # Send internal email directly within Phoenix
  defp send_internal_email(user_id, params, db_attachments) do
    # Merge db_attachments into params if provided
    params_with_db_attachments =
      if db_attachments do
        Map.put(params, :db_attachments, db_attachments)
      else
        params
      end

    with {:ok, _remaining} <- RateLimiter.check_rate_limit(user_id),
         {:ok, {mailbox, user}} <- get_user_mailbox_with_user(user_id),
         {:ok, _ownership} <- validate_from_address_ownership(params[:from], user_id),
         {:ok, formatted_params} <- format_from_header(params_with_db_attachments, user, mailbox),
         {:ok, message} <- deliver_internal_email(mailbox.id, formatted_params) do
      # Record successful send for rate limiting
      RateLimiter.record_send(user_id)
      {:ok, message}
    else
      {:error, :daily_limit_exceeded} ->
        Logger.warning("User #{user_id} exceeded daily email limit")
        {:error, :rate_limit_exceeded}

      {:error, :hourly_limit_exceeded} ->
        Logger.warning("User #{user_id} exceeded hourly email limit")
        {:error, :rate_limit_exceeded}

      {:error, :minute_limit_exceeded} ->
        Logger.warning("User #{user_id} exceeded per-minute email limit")
        {:error, :rate_limit_exceeded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Deliver internal email directly to recipient mailboxes
  defp deliver_internal_email(sender_mailbox_id, email_params) do
    to_emails = parse_email_list(email_params[:to] || "")
    cc_emails = parse_email_list(email_params[:cc] || "")
    bcc_emails = parse_email_list(email_params[:bcc] || "")

    # Check if this is a self-email (user emailing themselves)
    # BUT only if they're not forwarding to an external address
    sender_mailbox = Email.get_mailbox_internal(sender_mailbox_id)
    all_recipients = to_emails ++ cc_emails ++ bcc_emails

    # First check if any recipients have external forwarding (alias or mailbox)
    has_forwarding =
      Enum.any?(all_recipients, fn recipient_email ->
        clean_email = String.trim(String.downcase(recipient_email))

        # Check alias forwarding first
        case Email.resolve_alias(clean_email) do
          target_email when is_binary(target_email) ->
            # Has alias forwarding - check if it's external
            !is_internal_email?([target_email])

          _ ->
            # Check mailbox forwarding
            case Email.get_mailbox_by_email(clean_email) do
              %Mailbox{forward_enabled: true, forward_to: forward_to}
              when is_binary(forward_to) and forward_to != "" ->
                # Has mailbox forwarding - check if it's external
                !is_internal_email?([forward_to])

              _ ->
                false
            end
        end
      end)

    # Only consider it a self-email if ALL recipients are the sender
    is_self_email =
      !has_forwarding && sender_mailbox &&
        Enum.any?(all_recipients, fn recipient_email ->
          String.downcase(recipient_email) == String.downcase(sender_mailbox.email) ||
            is_user_alias?(recipient_email, sender_mailbox.user_id)
        end) &&
        Enum.all?(all_recipients, fn recipient_email ->
          String.downcase(recipient_email) == String.downcase(sender_mailbox.email) ||
            is_user_alias?(recipient_email, sender_mailbox.user_id)
        end)

    if is_self_email do
      # For self-emails, create both sent and received copies
      db_attachments = email_params[:db_attachments]

      # Always create sent copy regardless of source (webmail or SMTP)
      # Mobile clients and many email clients don't append to Sent via IMAP
      case store_sent_message_internal(sender_mailbox_id, email_params, db_attachments) do
        {:ok, _sent} ->
          # Store received copy
          store_self_received_message(sender_mailbox_id, email_params, db_attachments)

        error ->
          Logger.error("Self-email sent copy creation failed: #{inspect(error)}")
          error
      end
    else
      # Extract db_attachments if provided
      db_attachments = email_params[:db_attachments]

      # Store sent message first
      case store_sent_message_internal(sender_mailbox_id, email_params, db_attachments) do
        {:ok, sent_message} ->
          # Deliver to TO recipients
          Enum.each(to_emails, fn to_email ->
            deliver_to_internal_recipient(to_email, email_params, "to", db_attachments)
          end)

          # Deliver to CC recipients (they should see they were CC'd)
          Enum.each(cc_emails, fn cc_email ->
            # Filter out internal CC recipients that should receive a copy
            if is_internal_email?([cc_email]) do
              deliver_to_internal_recipient(cc_email, email_params, "cc", db_attachments)
            end
          end)

          # Deliver to BCC recipients (they shouldn't see BCC list)
          Enum.each(bcc_emails, fn bcc_email ->
            # Filter out internal BCC recipients that should receive a copy
            if is_internal_email?([bcc_email]) do
              # Create a copy of params without the BCC field for BCC recipients
              bcc_params = Map.put(email_params, :bcc, nil)
              deliver_to_internal_recipient(bcc_email, bcc_params, "bcc", db_attachments)
            end
          end)

          {:ok, sent_message}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Store sent message for internal delivery
  defp store_sent_message_internal(sender_mailbox_id, email_params, db_attachments) do
    # For internal emails, use full attachments (with data) not just S3 metadata
    # This allows recipients to download before async S3 upload completes
    attachments_to_store = email_params[:attachments] || db_attachments || %{}

    message_attrs = %{
      message_id: generate_message_id(),
      from: email_params[:from],
      to: email_params[:to],
      cc: email_params[:cc],
      bcc: email_params[:bcc],
      subject: email_params[:subject],
      text_body: email_params[:text_body],
      html_body: email_params[:html_body],
      attachments: attachments_to_store,
      mailbox_id: sender_mailbox_id,
      status: "sent",
      # Sent messages should not have a category
      category: nil,
      metadata: %{
        internal_delivery: true,
        sent_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    case Email.create_message(message_attrs) do
      {:ok, message} ->
        # Broadcast to webmail for real-time sync
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "mailbox:#{sender_mailbox_id}",
          {:new_email, message}
        )

        {:ok, message}

      {:error, :storage_limit_exceeded} ->
        {:error, :storage_limit_exceeded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Store sent message for external delivery (via Haraka/Swoosh)
  defp store_sent_message_external(
         sender_mailbox_id,
         email_params,
         swoosh_response,
         db_attachments
       ) do
    message_attrs = %{
      message_id: swoosh_response.message_id || generate_message_id(),
      from: email_params[:from],
      to: email_params[:to],
      cc: email_params[:cc],
      bcc: email_params[:bcc],
      subject: email_params[:subject],
      text_body: email_params[:text_body],
      html_body: email_params[:html_body],
      # Use S3 metadata if provided
      attachments: db_attachments || email_params[:attachments],
      mailbox_id: sender_mailbox_id,
      status: "sent",
      # Sent messages should not have a category
      category: nil,
      metadata: %{
        external_delivery: true,
        sent_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        original_message_id: swoosh_response.message_id
      }
    }

    case Email.create_message(message_attrs) do
      {:ok, message} ->
        # Broadcast to webmail for real-time sync
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "mailbox:#{sender_mailbox_id}",
          {:new_email, message}
        )

        {:ok, message}

      {:error, :storage_limit_exceeded} ->
        {:error, :storage_limit_exceeded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Deliver to internal recipient
  defp deliver_to_internal_recipient(to_email, email_params, recipient_type, db_attachments) do
    case find_internal_recipient_mailbox(to_email) do
      {:error, :forward_to_external} ->
        # This internal email needs to be forwarded to an external address
        # Get the actual forwarding target (try alias first, then mailbox)
        clean_email = String.trim(String.downcase(to_email))

        target_email =
          case Email.resolve_alias(clean_email) do
            alias_target when is_binary(alias_target) ->
              alias_target

            _ ->
              # Check mailbox forwarding
              case Email.get_mailbox_by_email(clean_email) do
                %Mailbox{forward_enabled: true, forward_to: mailbox_target}
                when is_binary(mailbox_target) and mailbox_target != "" ->
                  mailbox_target

                _ ->
                  nil
              end
          end

        case target_email do
          target when is_binary(target) ->
            # Send via external delivery with the target address
            forward_params = Map.put(email_params, :to, target)

            case send_via_swoosh(forward_params) do
              {:ok, _response} ->
                {:ok, :forwarded}

              {:error, reason} ->
                Logger.error("Failed to forward to #{target}: #{inspect(reason)}")
                {:error, reason}
            end

          nil ->
            {:error, :forward_target_not_found}
        end

      {:ok, recipient_mailbox} ->
        # For internal emails, use full attachments (with data) not just S3 metadata
        attachments_to_store = email_params[:attachments] || db_attachments || %{}

        # Create received message
        received_attrs = %{
          message_id: generate_message_id(),
          from: email_params[:from],
          to: email_params[:to],
          cc: email_params[:cc],
          bcc: email_params[:bcc],
          subject: email_params[:subject],
          text_body: email_params[:text_body],
          html_body: email_params[:html_body],
          attachments: attachments_to_store,
          mailbox_id: recipient_mailbox.id,
          status: "received",
          metadata: %{
            internal_delivery: true,
            recipient_type: recipient_type,
            received_at: DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }

        case Email.create_message(received_attrs) do
          {:ok, message} ->
            {:ok, message}

          {:error, reason} ->
            Logger.error("Failed to deliver internal email to #{to_email}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Could not find recipient mailbox for #{to_email}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Find recipient mailbox for internal delivery with loop detection
  defp find_internal_recipient_mailbox(email_address, visited \\ MapSet.new(), depth \\ 0)

  # Prevent infinite loops - max 10 hops
  defp find_internal_recipient_mailbox(_email_address, _visited, depth) when depth > 10 do
    Logger.error("Forwarding loop detected: exceeded maximum depth of 10 hops")
    {:error, :forwarding_loop_detected}
  end

  defp find_internal_recipient_mailbox(email_address, visited, depth) do
    clean_email = String.trim(String.downcase(email_address))

    # Check if we've already visited this address (circular loop)
    if MapSet.member?(visited, clean_email) do
      Logger.error(
        "Forwarding loop detected: #{clean_email} already visited in chain #{inspect(MapSet.to_list(visited))}"
      )

      {:error, :forwarding_loop_detected}
    else
      # Add current email to visited set
      visited = MapSet.put(visited, clean_email)

      # Check if this email has forwarding configured
      case Email.resolve_alias(clean_email) do
        # Alias forwards to another address
        target_email when is_binary(target_email) ->
          # Check if target is also internal
          if is_internal_email?([target_email]) do
            # Forward to internal address, find that mailbox recursively
            find_internal_recipient_mailbox(target_email, visited, depth + 1)
          else
            # Forward to external address - signal that this should be sent externally
            {:error, :forward_to_external}
          end

        # Alias exists but no forwarding - deliver to owner's mailbox
        :no_forward ->
          case Email.get_alias_by_email(clean_email) do
            %Email.Alias{user_id: user_id} when is_integer(user_id) ->
              case Email.get_user_mailbox(user_id) do
                %Mailbox{} = mailbox -> {:ok, mailbox}
                nil -> {:error, :no_mailbox}
              end

            _ ->
              {:error, :recipient_not_found}
          end

        # Not an alias, try direct mailbox match
        nil ->
          case Email.get_mailbox_by_email(clean_email) do
            %Mailbox{forward_enabled: true, forward_to: forward_to} = _mailbox
            when is_binary(forward_to) and forward_to != "" ->
              # Mailbox has forwarding enabled
              if is_internal_email?([forward_to]) do
                # Forward to internal address, find that mailbox recursively
                find_internal_recipient_mailbox(forward_to, visited, depth + 1)
              else
                # Forward to external address
                {:error, :forward_to_external}
              end

            %Mailbox{} = mailbox ->
              # No forwarding, deliver to this mailbox
              {:ok, mailbox}

            nil ->
              # Try cross-domain lookup (e.g., user@z.org -> user@elektrine.com)
              case try_cross_domain_mailbox_lookup(clean_email) do
                {:ok, mailbox} ->
                  # Check if cross-domain mailbox has forwarding
                  if mailbox.forward_enabled && mailbox.forward_to &&
                       String.trim(mailbox.forward_to) != "" do
                    if is_internal_email?([mailbox.forward_to]) do
                      find_internal_recipient_mailbox(mailbox.forward_to, visited, depth + 1)
                    else
                      {:error, :forward_to_external}
                    end
                  else
                    {:ok, mailbox}
                  end

                _ ->
                  {:error, :recipient_not_found}
              end
          end
      end
    end
  end

  # Generate unique message ID for internal delivery
  defp generate_message_id do
    "internal-#{System.system_time(:millisecond)}-#{:rand.uniform(999_999)}"
  end

  # Check if email address is an alias owned by the user
  defp is_user_alias?(email_address, user_id) do
    case Email.get_alias_by_email(email_address) do
      %Email.Alias{user_id: ^user_id, enabled: true} -> true
      _ -> false
    end
  end

  # Check if two email addresses belong to the same user across domains
  defp is_same_user_cross_domain?(email1, email2) do
    case {parse_email_parts(email1), parse_email_parts(email2)} do
      {{username1, domain1}, {username2, domain2}} ->
        # Same username and both are our domains
        supported_domains = ["elektrine.com", "z.org"]

        String.downcase(username1) == String.downcase(username2) &&
          domain1 in supported_domains &&
          domain2 in supported_domains

      _ ->
        false
    end
  end

  # Parse email into username and domain
  defp parse_email_parts(email) do
    case String.split(String.trim(String.downcase(email)), "@") do
      [username, domain] -> {username, domain}
      _ -> nil
    end
  end

  # Helper to deliver to a single CC or BCC recipient
  defp deliver_to_cc_or_bcc_recipient(
         recipient_email,
         email_params,
         recipient_type,
         sender_mailbox,
         db_attachments
       ) do
    # Check if this is an internal recipient or the sender themselves
    # Also check cross-domain (elektrine.com <-> z.org)
    is_internal = is_internal_email?([recipient_email])

    is_sender =
      sender_mailbox && is_same_user_cross_domain?(recipient_email, sender_mailbox.email)

    is_alias = sender_mailbox && is_user_alias?(recipient_email, sender_mailbox.user_id)

    if is_internal || is_sender || is_alias do
      # Deliver copy to their inbox
      case find_internal_recipient_mailbox(recipient_email) do
        {:error, :forward_to_external} ->
          # This recipient has external forwarding - send via external delivery
          clean_email = String.trim(String.downcase(recipient_email))

          target_email =
            case Email.resolve_alias(clean_email) do
              alias_target when is_binary(alias_target) ->
                alias_target

              _ ->
                case Email.get_mailbox_by_email(clean_email) do
                  %Mailbox{forward_enabled: true, forward_to: mailbox_target}
                  when is_binary(mailbox_target) and mailbox_target != "" ->
                    mailbox_target

                  _ ->
                    nil
                end
            end

          case target_email do
            target when is_binary(target) ->
              # For BCC, hide the BCC list when forwarding
              forward_params =
                if recipient_type == "bcc" do
                  email_params
                  |> Map.put(:to, target)
                  |> Map.put(:bcc, nil)
                else
                  Map.put(email_params, :to, target)
                end

              case send_via_swoosh(forward_params) do
                {:ok, _response} ->
                  :ok

                {:error, reason} ->
                  Logger.error(
                    "Failed to forward #{String.upcase(recipient_type)} to #{target}: #{inspect(reason)}"
                  )
              end

            _ ->
              :ok
          end

        {:ok, recipient_mailbox} ->
          # For internal emails, use full attachments (with data)
          attachments_to_store = email_params[:attachments] || db_attachments || %{}

          # Create received message (hide BCC list for BCC recipients)
          received_attrs = %{
            message_id: generate_message_id(),
            from: email_params[:from],
            to: email_params[:to],
            cc: email_params[:cc],
            # Hide BCC for BCC recipients
            bcc: if(recipient_type == "bcc", do: nil, else: email_params[:bcc]),
            subject: email_params[:subject],
            text_body: email_params[:text_body],
            html_body: email_params[:html_body],
            attachments: attachments_to_store,
            mailbox_id: recipient_mailbox.id,
            status: "received",
            metadata: %{
              internal_delivery: true,
              recipient_type: recipient_type,
              received_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }

          case Email.create_message(received_attrs) do
            {:ok, _message} ->
              :ok

            {:error, reason} ->
              Logger.error(
                "Failed to deliver to #{String.upcase(recipient_type)} recipient #{recipient_email}: #{inspect(reason)}"
              )
          end

        {:error, reason} ->
          Logger.warning(
            "Could not find mailbox for #{String.upcase(recipient_type)} recipient #{recipient_email}: #{inspect(reason)}"
          )
      end
    end
  end

  # Deliver to internal CC/BCC recipients when sending external email
  defp deliver_to_internal_cc_bcc_recipients(sender_mailbox_id, email_params, db_attachments) do
    cc_emails = parse_email_list(email_params[:cc] || "")
    bcc_emails = parse_email_list(email_params[:bcc] || "")

    sender_mailbox = Email.get_mailbox_internal(sender_mailbox_id)

    # Process CC recipients
    Enum.each(cc_emails, fn cc_email ->
      deliver_to_cc_or_bcc_recipient(cc_email, email_params, "cc", sender_mailbox, db_attachments)
    end)

    # Process BCC recipients
    Enum.each(bcc_emails, fn bcc_email ->
      deliver_to_cc_or_bcc_recipient(
        bcc_email,
        email_params,
        "bcc",
        sender_mailbox,
        db_attachments
      )
    end)

    :ok
  end

  # Try to find a mailbox by cross-domain lookup (e.g., user@z.org -> user@elektrine.com)
  defp try_cross_domain_mailbox_lookup(email_address) do
    case String.split(email_address, "@") do
      [username, domain] ->
        supported_domains = ["elektrine.com", "z.org"]

        if domain in supported_domains do
          # Try the other supported domain
          other_domain =
            case domain do
              "elektrine.com" -> "z.org"
              "z.org" -> "elektrine.com"
              _ -> nil
            end

          if other_domain do
            other_email = "#{username}@#{other_domain}"

            case Email.get_mailbox_by_email(other_email) do
              %Mailbox{} = mailbox -> {:ok, mailbox}
              _ -> {:error, :not_found}
            end
          else
            {:error, :not_found}
          end
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :invalid_email}
    end
  end

  # Store received copy of self-email
  defp store_self_received_message(sender_mailbox_id, email_params, db_attachments) do
    # For internal emails, use full attachments (with data) not just S3 metadata
    attachments_to_store = email_params[:attachments] || db_attachments || %{}

    message_attrs = %{
      message_id: generate_message_id(),
      from: email_params[:from],
      to: email_params[:to],
      cc: email_params[:cc],
      bcc: email_params[:bcc],
      subject: email_params[:subject],
      text_body: email_params[:text_body],
      html_body: email_params[:html_body],
      attachments: attachments_to_store,
      mailbox_id: sender_mailbox_id,
      status: "received",
      category: "inbox",
      metadata: %{
        internal_delivery: true,
        self_email: true,
        sent_and_received: true,
        delivered_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    case Email.create_message(message_attrs) do
      {:ok, message} ->
        {:ok, message}

      {:error, reason} ->
        Logger.error("Failed to create self-email received copy: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Validates that there is at least one valid recipient
  defp validate_recipients(recipients) when is_list(recipients) do
    # Filter out empty recipients first
    non_empty_recipients =
      recipients
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # Check if we have any recipients at all
    if Enum.empty?(non_empty_recipients) do
      {:error, "At least one valid recipient is required (To, CC, or BCC)"}
    else
      # Check for suspicious content first (before format validation)
      if Enum.any?(non_empty_recipients, &contains_suspicious_content?/1) do
        {:error, "Invalid recipient address detected"}
      else
        # Then check email format
        valid_recipients = Enum.filter(non_empty_recipients, &valid_email_format?/1)

        if Enum.empty?(valid_recipients) do
          {:error, "At least one valid recipient is required (To, CC, or BCC)"}
        else
          :ok
        end
      end
    end
  end

  # Validate email format
  defp valid_email_format?(email) when is_binary(email) do
    String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  end

  defp valid_email_format?(_), do: false

  # Check for suspicious content in email addresses
  defp contains_suspicious_content?(email) when is_binary(email) do
    suspicious_patterns = [
      # Script tags
      ~r/<script/i,
      # Iframes
      ~r/<iframe/i,
      # JavaScript protocol
      ~r/javascript:/i,
      # Data URLs
      ~r/data:/i,
      # HTML brackets
      ~r/[<>]/,
      # Line breaks
      ~r/[\r\n]/,
      # Semicolons (injection attempts)
      ~r/[;]/
    ]

    Enum.any?(suspicious_patterns, &String.match?(email, &1))
  end

  # PGP Encryption Support
  # Attempts to encrypt the email if the primary recipient has a PGP public key
  defp maybe_pgp_encrypt(params, user_id) do
    # Only encrypt if not already encrypted and we have a body to encrypt
    if params[:pgp_encrypted] do
      params
    else
      # Get primary recipient (first TO address)
      to_emails = parse_email_list(params[:to] || "")

      case to_emails do
        [primary_recipient | _rest] ->
          # Check if this recipient has a PGP key
          case PGP.lookup_recipient_key(primary_recipient, user_id) do
            {:ok, public_key} ->
              encrypt_email_body(params, public_key, primary_recipient)

            {:error, _} ->
              # No key available, send unencrypted
              params
          end

        [] ->
          params
      end
    end
  end

  defp encrypt_email_body(params, public_key, recipient_email) do
    # Get the body to encrypt (prefer text, create text from html if needed)
    text_body = params[:text_body]
    html_body = params[:html_body]

    body_to_encrypt =
      cond do
        text_body && String.trim(text_body) != "" ->
          text_body

        html_body && String.trim(html_body) != "" ->
          # Convert HTML to plain text for encryption
          html_body
          |> String.replace(~r/<br\s*\/?>/, "\n")
          |> String.replace(~r/<\/p>/, "\n\n")
          |> String.replace(~r/<[^>]+>/, "")
          |> HtmlEntities.decode()

        true ->
          nil
      end

    if body_to_encrypt do
      case PGP.encrypt(body_to_encrypt, public_key) do
        {:ok, encrypted} ->
          # Replace body with encrypted content
          params
          |> Map.put(:text_body, encrypted)
          # Remove HTML body - PGP is text-only
          |> Map.put(:html_body, nil)
          |> Map.put(:pgp_encrypted, true)

        {:error, reason} ->
          Logger.warning("PGP: Failed to encrypt email to #{recipient_email}: #{inspect(reason)}")
          # Send unencrypted if encryption fails
          params
      end
    else
      params
    end
  end

  # Filter out unsubscribed recipients from email lists
  defp filter_unsubscribed_recipients(to_emails, cc_emails, bcc_emails, list_id) do
    filtered_to = Enum.reject(to_emails, &Unsubscribes.unsubscribed?(&1, list_id))
    filtered_cc = Enum.reject(cc_emails, &Unsubscribes.unsubscribed?(&1, list_id))
    filtered_bcc = Enum.reject(bcc_emails, &Unsubscribes.unsubscribed?(&1, list_id))

    # Check if all recipients were filtered out
    if Enum.empty?(filtered_to) && Enum.empty?(filtered_cc) && Enum.empty?(filtered_bcc) do
      {:error, :all_unsubscribed}
    else
      {:ok, filtered_to, filtered_cc, filtered_bcc}
    end
  end

  # Check if an email is transactional (should not honor unsubscribes)
  # Transactional emails include: password resets, account notifications, etc.
  defp is_transactional_email?(list_id) do
    ListTypes.transactional?(list_id)
  end

  # VPN Quota Notification Emails

  def send_vpn_quota_warning(user, user_config, threshold) do
    quota_gb = (user_config.bandwidth_quota_bytes / 1_073_741_824) |> Float.round(1)
    used_gb = (user_config.quota_used_bytes / 1_073_741_824) |> Float.round(1)
    remaining_gb = Float.round(quota_gb - used_gb, 1)
    safe_username = String.replace(user.username, ~r/[\r\n]/, "")
    safe_server_name = String.replace(user_config.vpn_server.name, ~r/[\r\n]/, "")
    reset_date = format_reset_date(user_config.quota_period_start)

    text_body = """
    Hello #{safe_username},

    Your VPN bandwidth usage has reached #{threshold}% of your monthly quota.

    Current Usage: #{used_gb} GB / #{quota_gb} GB
    Server: #{safe_server_name}

    You have #{remaining_gb} GB remaining this month.
    Your quota will reset on #{reset_date}.

    To avoid service interruption, please monitor your usage.

    Best regards,
    Elektrine Team
    """

    html_body = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <meta name="color-scheme" content="dark">
      <meta name="supported-color-schemes" content="dark">
    </head>
    <body style="margin: 0; padding: 0; background-color: #000000; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #000000;">
        <tr>
          <td align="center" style="padding: 40px 20px;">
            <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width: 600px; background-color: #0a0a0a; border: 1px solid #1f1f1f; border-radius: 12px;">
              <tr>
                <td style="padding: 40px;">
                  <!-- Header -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding-bottom: 30px; border-bottom: 1px solid #1f1f1f;">
                        <h1 style="margin: 0; color: #f97316; font-size: 24px; font-weight: 600;">VPN Bandwidth Warning</h1>
                      </td>
                    </tr>
                  </table>

                  <!-- Alert Box -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding: 20px 0;">
                        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #1c1917; border: 1px solid #f97316; border-radius: 8px;">
                          <tr>
                            <td style="padding: 16px; text-align: center;">
                              <p style="margin: 0 0 8px 0; color: #f97316; font-size: 36px; font-weight: 700;">#{threshold}%</p>
                              <p style="margin: 0; color: #fed7aa; font-size: 14px;">of monthly quota used</p>
                            </td>
                          </tr>
                        </table>
                      </td>
                    </tr>
                  </table>

                  <!-- Content -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding: 10px 0 30px 0;">
                        <p style="margin: 0 0 20px 0; color: #e5e5e5; font-size: 16px; line-height: 1.6;">
                          Hello #{safe_username},
                        </p>
                        <p style="margin: 0 0 25px 0; color: #d1d5db; font-size: 16px; line-height: 1.6;">
                          Your VPN bandwidth usage has reached #{threshold}% of your monthly quota.
                        </p>

                        <!-- Stats -->
                        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #171717; border-radius: 8px; margin: 0 0 25px 0;">
                          <tr>
                            <td style="padding: 20px;">
                              <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                                <tr>
                                  <td style="color: #9ca3af; font-size: 14px; padding-bottom: 12px;">Current Usage</td>
                                  <td style="color: #e5e5e5; font-size: 14px; text-align: right; padding-bottom: 12px;">#{used_gb} GB / #{quota_gb} GB</td>
                                </tr>
                                <tr>
                                  <td style="color: #9ca3af; font-size: 14px; padding-bottom: 12px;">Server</td>
                                  <td style="color: #e5e5e5; font-size: 14px; text-align: right; padding-bottom: 12px;">#{safe_server_name}</td>
                                </tr>
                                <tr>
                                  <td style="color: #9ca3af; font-size: 14px; padding-bottom: 12px;">Remaining</td>
                                  <td style="color: #22c55e; font-size: 14px; text-align: right; padding-bottom: 12px;">#{remaining_gb} GB</td>
                                </tr>
                                <tr>
                                  <td style="color: #9ca3af; font-size: 14px;">Resets On</td>
                                  <td style="color: #e5e5e5; font-size: 14px; text-align: right;">#{reset_date}</td>
                                </tr>
                              </table>
                            </td>
                          </tr>
                        </table>

                        <p style="margin: 0; color: #9ca3af; font-size: 14px; line-height: 1.6;">
                          To avoid service interruption, please monitor your usage.
                        </p>
                      </td>
                    </tr>
                  </table>

                  <!-- Footer -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding-top: 30px; border-top: 1px solid #1f1f1f;">
                        <p style="margin: 0; color: #6b7280; font-size: 12px;">
                          Best regards,<br>Elektrine Team
                        </p>
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
            </table>
          </td>
        </tr>
      </table>
    </body>
    </html>
    """

    user_email = "#{user.username}@#{user.preferred_email_domain || "elektrine.com"}"

    %Swoosh.Email{}
    |> Swoosh.Email.to({user.username, user_email})
    |> Swoosh.Email.from({"Elektrine", "noreply@elektrine.com"})
    |> Swoosh.Email.subject("VPN Bandwidth Warning - #{threshold}% Used")
    |> Swoosh.Email.text_body(text_body)
    |> Swoosh.Email.html_body(html_body)
    |> Elektrine.Mailer.deliver()
  end

  def send_vpn_quota_suspended(user, user_config) do
    quota_gb = (user_config.bandwidth_quota_bytes / 1_073_741_824) |> Float.round(1)
    used_gb = (user_config.quota_used_bytes / 1_073_741_824) |> Float.round(1)
    safe_username = String.replace(user.username, ~r/[\r\n]/, "")
    safe_server_name = String.replace(user_config.vpn_server.name, ~r/[\r\n]/, "")
    reset_date = format_reset_date(user_config.quota_period_start)

    text_body = """
    Hello #{safe_username},

    Your VPN service has been temporarily suspended because you have exceeded your monthly bandwidth quota.

    Current Usage: #{used_gb} GB / #{quota_gb} GB
    Server: #{safe_server_name}

    Your quota will automatically reset on #{reset_date}.

    If you need additional bandwidth, please contact support or wait for the monthly reset.

    Best regards,
    Elektrine Team
    """

    html_body = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <meta name="color-scheme" content="dark">
      <meta name="supported-color-schemes" content="dark">
    </head>
    <body style="margin: 0; padding: 0; background-color: #000000; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #000000;">
        <tr>
          <td align="center" style="padding: 40px 20px;">
            <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width: 600px; background-color: #0a0a0a; border: 1px solid #1f1f1f; border-radius: 12px;">
              <tr>
                <td style="padding: 40px;">
                  <!-- Header -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding-bottom: 30px; border-bottom: 1px solid #1f1f1f;">
                        <h1 style="margin: 0; color: #ef4444; font-size: 24px; font-weight: 600;">VPN Service Suspended</h1>
                      </td>
                    </tr>
                  </table>

                  <!-- Alert Box -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding: 20px 0;">
                        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #1c1917; border: 1px solid #ef4444; border-radius: 8px;">
                          <tr>
                            <td style="padding: 16px; text-align: center;">
                              <p style="margin: 0 0 8px 0; color: #ef4444; font-size: 18px; font-weight: 600;">Quota Exceeded</p>
                              <p style="margin: 0; color: #fca5a5; font-size: 14px;">Your VPN service has been temporarily suspended</p>
                            </td>
                          </tr>
                        </table>
                      </td>
                    </tr>
                  </table>

                  <!-- Content -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding: 10px 0 30px 0;">
                        <p style="margin: 0 0 20px 0; color: #e5e5e5; font-size: 16px; line-height: 1.6;">
                          Hello #{safe_username},
                        </p>
                        <p style="margin: 0 0 25px 0; color: #d1d5db; font-size: 16px; line-height: 1.6;">
                          Your VPN service has been temporarily suspended because you have exceeded your monthly bandwidth quota.
                        </p>

                        <!-- Stats -->
                        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #171717; border-radius: 8px; margin: 0 0 25px 0;">
                          <tr>
                            <td style="padding: 20px;">
                              <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                                <tr>
                                  <td style="color: #9ca3af; font-size: 14px; padding-bottom: 12px;">Current Usage</td>
                                  <td style="color: #ef4444; font-size: 14px; text-align: right; padding-bottom: 12px;">#{used_gb} GB / #{quota_gb} GB</td>
                                </tr>
                                <tr>
                                  <td style="color: #9ca3af; font-size: 14px; padding-bottom: 12px;">Server</td>
                                  <td style="color: #e5e5e5; font-size: 14px; text-align: right; padding-bottom: 12px;">#{safe_server_name}</td>
                                </tr>
                                <tr>
                                  <td style="color: #9ca3af; font-size: 14px;">Quota Resets</td>
                                  <td style="color: #22c55e; font-size: 14px; text-align: right;">#{reset_date}</td>
                                </tr>
                              </table>
                            </td>
                          </tr>
                        </table>

                        <p style="margin: 0; color: #9ca3af; font-size: 14px; line-height: 1.6;">
                          If you need additional bandwidth, please contact support or wait for the monthly reset.
                        </p>
                      </td>
                    </tr>
                  </table>

                  <!-- Footer -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding-top: 30px; border-top: 1px solid #1f1f1f;">
                        <p style="margin: 0; color: #6b7280; font-size: 12px;">
                          Best regards,<br>Elektrine Team
                        </p>
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
            </table>
          </td>
        </tr>
      </table>
    </body>
    </html>
    """

    user_email = "#{user.username}@#{user.preferred_email_domain || "elektrine.com"}"

    %Swoosh.Email{}
    |> Swoosh.Email.to({user.username, user_email})
    |> Swoosh.Email.from({"Elektrine", "noreply@elektrine.com"})
    |> Swoosh.Email.subject("VPN Service Suspended - Quota Exceeded")
    |> Swoosh.Email.text_body(text_body)
    |> Swoosh.Email.html_body(html_body)
    |> Elektrine.Mailer.deliver()
  end

  defp format_reset_date(quota_period_start) when is_nil(quota_period_start) do
    "next month"
  end

  defp format_reset_date(quota_period_start) do
    reset_date = DateTime.add(quota_period_start, 30, :day)
    Calendar.strftime(reset_date, "%B %d, %Y")
  end

  @doc """
  Forwards an email message to another address.
  Used by email filters to automatically forward incoming messages.

  ## Parameters
    * `message` - The email message struct to forward
    * `forward_to` - The email address to forward to

  ## Returns
    * `:ok` - If forwarded successfully
    * `{:error, reason}` - If forwarding failed
  """
  def forward_message(message, forward_to) do
    subject = "Fwd: #{message.subject || "(no subject)"}"

    # Build forward header
    forward_header = """
    ---------- Forwarded message ----------
    From: #{message.from}
    Date: #{format_datetime(message.inserted_at)}
    Subject: #{message.subject || "(no subject)"}
    To: #{message.to}
    """

    text_body =
      if message.text_body do
        forward_header <> "\n\n" <> message.text_body
      else
        forward_header
      end

    html_body =
      if message.html_body do
        """
        <div style="margin-bottom: 16px; padding: 12px; background: #f5f5f5; border-left: 3px solid #ccc;">
          <strong>---------- Forwarded message ----------</strong><br>
          <strong>From:</strong> #{Phoenix.HTML.html_escape(message.from) |> Phoenix.HTML.safe_to_string()}<br>
          <strong>Date:</strong> #{format_datetime(message.inserted_at)}<br>
          <strong>Subject:</strong> #{Phoenix.HTML.html_escape(message.subject || "(no subject)") |> Phoenix.HTML.safe_to_string()}<br>
          <strong>To:</strong> #{Phoenix.HTML.html_escape(message.to) |> Phoenix.HTML.safe_to_string()}
        </div>
        #{message.html_body}
        """
      else
        nil
      end

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(forward_to)
      |> Swoosh.Email.from({"Elektrine Forwarding", "noreply@elektrine.com"})
      |> Swoosh.Email.subject(subject)
      |> Swoosh.Email.text_body(text_body)

    email =
      if html_body do
        Swoosh.Email.html_body(email, html_body)
      else
        email
      end

    case Elektrine.Mailer.deliver(email) do
      {:ok, _} ->
        Logger.info("Forwarded message #{message.id} to #{forward_to}")
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to forward message #{message.id} to #{forward_to}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %b %d, %Y at %I:%M %p")
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime()
  end

  defp format_datetime(_), do: "Unknown date"
end
