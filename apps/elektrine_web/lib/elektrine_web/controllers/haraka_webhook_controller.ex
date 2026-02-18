defmodule ElektrineWeb.HarakaWebhookController do
  use ElektrineWeb, :controller
  require Logger

  alias Elektrine.Webhook.RateLimiter, as: WebhookRateLimiter
  alias Elektrine.Email.ForwardedMessage
  alias Elektrine.Email.HeaderDecoder
  alias Elektrine.Email.InboundRouting
  alias Elektrine.Email.Suppressions
  alias Elektrine.Email.Sanitizer
  alias Elektrine.Email.HeaderSanitizer
  alias Elektrine.Repo
  alias Elektrine.Telemetry.Events
  alias ElektrineWeb.HarakaInboundWorker

  @hard_bounce_indicators [
    "user unknown",
    "unknown user",
    "no such user",
    "mailbox unavailable",
    "recipient address rejected",
    "address rejected",
    "does not exist",
    "invalid recipient",
    "account disabled"
  ]

  @soft_bounce_indicators [
    "mailbox full",
    "temporarily deferred",
    "temporary failure",
    "try again later",
    "resources temporarily unavailable",
    "over quota"
  ]

  # API key for webhook authentication is loaded at runtime from environment variables

  # Verify if a recipient email address exists
  def verify_recipient(conn, %{"email" => email}) do
    with :ok <- authenticate(conn) do
      # Check if mailbox exists for this email
      case InboundRouting.resolve_recipient_mailbox(email, email) do
        {:ok, _mailbox} ->
          conn
          |> put_status(:ok)
          |> json(%{exists: true, email: email})

        {:forward_external, _target, _alias_email} ->
          # Email is an alias that forwards externally - accept it
          conn
          |> put_status(:ok)
          |> json(%{exists: true, email: email})

        {:error, _reason} ->
          # Mailbox does not exist
          conn
          |> put_status(:not_found)
          |> json(%{exists: false, email: email})
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"})
    end
  end

  def verify_recipient(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required field: email"})
  end

  # Authenticate SMTP user credentials
  def auth(conn, %{"username" => username, "password" => password}) do
    with :ok <- authenticate(conn) do
      # Authenticate user via app password
      case Elektrine.Accounts.authenticate_with_app_password(username, password) do
        {:ok, _user} ->
          conn
          |> put_status(:ok)
          |> json(%{authenticated: true})

        {:error, _reason} ->
          conn
          |> put_status(:unauthorized)
          |> json(%{authenticated: false, error: "Invalid credentials"})
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized - Invalid API key"})
    end
  end

  def auth(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required fields: username and password"})
  end

  # List all domains accepted by this instance
  # Called by Haraka to know which domains to accept mail for
  def domains(conn, _params) do
    with :ok <- authenticate(conn) do
      domains =
        Application.get_env(:elektrine, :email)[:supported_domains] || ["elektrine.com", "z.org"]

      conn
      |> put_status(:ok)
      |> json(%{domains: domains})
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"})
    end
  end

  def create(conn, params) do
    start_time = System.monotonic_time(:millisecond)

    # Track request for rate limiting
    remote_ip = get_remote_ip(conn)

    with :ok <- authenticate(conn),
         :ok <- validate_request_size(conn),
         :ok <- check_rate_limit(remote_ip) do
      if async_ingest_enabled?() do
        handle_async_ingest(conn, params, remote_ip, start_time)
      else
        try do
          # Process Haraka webhook format
          case process_haraka_email(params, %{
                 "ingest_mode" => "sync",
                 "remote_ip" => remote_ip
               }) do
            {:ok, email} ->
              duration = System.monotonic_time(:millisecond) - start_time
              Events.email_inbound(:webhook, :success, duration, %{source: :haraka})

              conn
              |> put_status(:ok)
              |> json(%{
                status: "success",
                message_id: email.id,
                processing_time_ms: duration
              })

            {:error, reason} ->
              duration = System.monotonic_time(:millisecond) - start_time

              Events.email_inbound(:webhook, :failure, duration, %{
                reason: reason,
                source: :haraka
              })

              # Security rejections are expected (spam/spoofing blocked) - don't log as errors
              if reason == :security_rejection do
                Logger.debug(
                  "Security rejection for email from #{params["from"]} (#{duration}ms)"
                )
              else
                Logger.error("Failed to process Haraka email: #{inspect(reason)} (#{duration}ms)")

                # Get attachment info for debugging
                raw_attachments = params["attachments"]

                attachment_info =
                  case raw_attachments do
                    list when is_list(list) ->
                      %{format: "list", count: length(list)}

                    map when is_map(map) ->
                      %{format: "map", count: map_size(map), keys: Map.keys(map)}

                    nil ->
                      %{format: "nil", count: 0}

                    other ->
                      %{format: inspect(other.__struct__ || "unknown"), count: 0}
                  end

                # Report to Sentry - but NOT security rejections (expected behavior)
                Sentry.capture_message("Failed to process inbound email",
                  level: if(reason == :no_mailbox, do: :warning, else: :error),
                  extra: %{
                    reason: inspect(reason),
                    duration_ms: duration,
                    to: params["to"],
                    rcpt_to: params["rcpt_to"],
                    from: params["from"],
                    attachment_info: attachment_info,
                    subject: params["subject"]
                  }
                )
              end

              # Return appropriate status code for bouncing
              {status_code, error_message} = get_bounce_status(reason)

              conn
              |> put_status(status_code)
              |> json(%{
                error: error_message,
                processing_time_ms: duration,
                bounce: true
              })
          end
        rescue
          e ->
            Logger.error("Error processing Haraka email: #{inspect(e)}")
            Logger.error("Stack trace: #{Exception.format_stacktrace()}")
            duration = System.monotonic_time(:millisecond) - start_time

            Events.email_inbound(:webhook, :failure, duration, %{
              reason: :exception,
              source: :haraka
            })

            # Get attachment info for debugging
            raw_attachments = params["attachments"]

            attachment_info =
              case raw_attachments do
                list when is_list(list) ->
                  %{format: "list", count: length(list)}

                map when is_map(map) ->
                  %{format: "map", count: map_size(map), keys: Map.keys(map)}

                nil ->
                  %{format: "nil", count: 0}

                _ ->
                  %{format: "unknown", count: 0}
              end

            # Report exception to Sentry
            Sentry.capture_exception(e,
              stacktrace: __STACKTRACE__,
              extra: %{
                context: "haraka_webhook_processing",
                attachment_info: attachment_info,
                to: params["to"],
                from: params["from"],
                subject: params["subject"]
              }
            )

            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Internal server error"})
        end
      end
    else
      {:error, :unauthorized} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Events.email_inbound(:webhook, :failure, duration, %{
          reason: :unauthorized,
          source: :haraka
        })

        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"})

      {:error, :request_too_large} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Events.email_inbound(:webhook, :failure, duration, %{
          reason: :request_too_large,
          source: :haraka
        })

        conn |> put_status(:payload_too_large) |> json(%{error: "Request too large"})

      {:error, :invalid_content_length} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Events.email_inbound(:webhook, :failure, duration, %{
          reason: :invalid_content_length,
          source: :haraka
        })

        conn |> put_status(:bad_request) |> json(%{error: "Invalid Content-Length header"})

      {:error, :rate_limit_exceeded} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Events.email_inbound(:webhook, :rate_limited, duration, %{
          reason: :rate_limit,
          source: :haraka
        })

        conn |> put_status(:too_many_requests) |> json(%{error: "Rate limited"})
    end
  end

  @doc false
  def process_haraka_email_public(params, ingest_context \\ %{})
      when is_map(params) and is_map(ingest_context) do
    process_haraka_email(params, ingest_context)
  end

  defp handle_async_ingest(conn, params, remote_ip, start_time) do
    try do
      case enqueue_haraka_email(params, remote_ip) do
        {:ok, %{job_id: job_id, outcome: outcome, idempotency_key: idempotency_key}} ->
          duration = System.monotonic_time(:millisecond) - start_time

          Events.email_inbound(:webhook_enqueue, outcome, duration, %{
            source: :haraka,
            queue: :email_inbound,
            job_id: job_id
          })

          conn
          |> put_status(:ok)
          |> json(%{
            status: "queued",
            queue: "email_inbound",
            enqueue_outcome: Atom.to_string(outcome),
            job_id: job_id,
            idempotency_key: idempotency_key,
            processing_time_ms: duration
          })

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - start_time

          Events.email_inbound(:webhook_enqueue, :failure, duration, %{
            reason: reason,
            source: :haraka,
            queue: :email_inbound
          })

          {status_code, error_message} = get_bounce_status(reason)

          conn
          |> put_status(status_code)
          |> json(%{
            error: error_message,
            processing_time_ms: duration,
            bounce: true
          })
      end
    rescue
      e ->
        Logger.error("Error enqueueing Haraka email: #{inspect(e)}")
        Logger.error("Stack trace: #{Exception.format_stacktrace()}")
        duration = System.monotonic_time(:millisecond) - start_time

        Events.email_inbound(:webhook_enqueue, :failure, duration, %{
          reason: :exception,
          source: :haraka,
          queue: :email_inbound
        })

        Sentry.capture_exception(e,
          stacktrace: __STACKTRACE__,
          extra: %{
            context: "haraka_webhook_enqueue",
            to: params["to"],
            rcpt_to: params["rcpt_to"],
            from: params["from"],
            subject: params["subject"]
          }
        )

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Internal server error"})
    end
  end

  defp enqueue_haraka_email(params, remote_ip) do
    idempotency_key = HarakaInboundWorker.idempotency_key(params)

    with :ok <- preflight_recipient_check(params) do
      if already_processed_payload?(params) do
        {:ok,
         %{
           job_id: nil,
           outcome: :duplicate,
           idempotency_key: idempotency_key
         }}
      else
        with {:ok, job, outcome} <- HarakaInboundWorker.enqueue(params, remote_ip: remote_ip) do
          {:ok,
           %{
             job_id: job.id,
             outcome: outcome,
             idempotency_key: job.args["idempotency_key"] || idempotency_key
           }}
        end
      end
    end
  end

  defp preflight_recipient_check(params) do
    to = get_header_value(params, "to", "rcpt_to")
    rcpt_to = params["rcpt_to"] || to

    case InboundRouting.resolve_recipient_mailbox(to, rcpt_to) do
      {:ok, _mailbox} ->
        :ok

      {:forward_external, _target, _alias_email} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp already_processed_payload?(params) do
    import Ecto.Query, only: [from: 2]

    message_id = params["message_id"]
    to = get_header_value(params, "to", "rcpt_to")
    rcpt_to = params["rcpt_to"] || to

    if is_binary(message_id) and String.trim(message_id) != "" do
      case InboundRouting.resolve_recipient_mailbox(to, rcpt_to) do
        {:ok, mailbox} ->
          query =
            from(m in Elektrine.Email.Message,
              where: m.mailbox_id == ^mailbox.id and m.message_id == ^message_id,
              limit: 1
            )

          not is_nil(Repo.one(query))

        _ ->
          false
      end
    else
      false
    end
  end

  defp async_ingest_enabled? do
    case Application.get_env(:elektrine, :haraka_async_ingest, false) do
      true -> true
      false -> false
      _ -> false
    end
  end

  # Process Haraka email webhook
  defp process_haraka_email(params, ingest_context) do
    try do
      # Inbound boundary order:
      # 1) Extract + normalize incoming payload.
      # 2) Run security checks.
      # 3) Sanitize once before persistence/forwarding.

      # Extract email fields from Haraka webhook format
      message_id =
        params["message_id"] ||
          "haraka-#{:rand.uniform(1_000_000)}-#{System.system_time(:millisecond)}"

      # Use Mail library for proper RFC 2047 MIME header decoding
      # Extract and decode headers - use helper to handle empty strings properly
      from = get_header_value(params, "from", "mail_from") || "unknown@example.com"
      to = get_header_value(params, "to", "rcpt_to") || "unknown@elektrine.com"
      subject = extract_subject(params)

      # Security validations for inbound email
      # 1. Check for local domain spoofing (external sender claiming to be from our domain)
      # Only trust explicit authenticated-submission metadata or signed internal-origin headers.
      authenticated_context =
        if trusted_local_sender?(params, from), do: %{authenticated: true}, else: nil

      case HeaderSanitizer.check_local_domain_spoofing(from, authenticated_context) do
        {:error, reason} ->
          throw({:security_rejection, reason})

        _ ->
          :ok
      end

      # 2. Check for backscatter/bounce attack
      case HeaderSanitizer.check_bounce_attack(%{from: from, to: to, subject: subject}) do
        {:error, reason} ->
          throw({:security_rejection, reason})

        _ ->
          :ok
      end

      # 3. Check for multiple From headers in raw email (if available)
      if params["raw"] do
        case HeaderSanitizer.check_multiple_from_headers(params["raw"]) do
          {:error, reason} ->
            throw({:security_rejection, reason})

          _ ->
            :ok
        end
      end

      # Extract body content from Haraka webhook
      # Haraka uses mailparser which properly handles MIME structure
      # CRITICAL: Ensure UTF-8 validity FIRST to prevent crashes on String operations
      raw_text_body = ensure_safe_utf8(params["text_body"] || "")
      raw_html_body = ensure_safe_utf8(params["html_body"] || "")
      # Normalize attachments to list format (Haraka may send as map with "attachment_0" keys)
      raw_attachments = normalize_attachments_to_list(params["attachments"])

      # Check if this is a PGP/MIME email (encrypted payload in attachments)
      # PGP/MIME emails have encrypted data as attachment, not in text_body
      {text_body, html_body, attachments} =
        reconstruct_pgp_mime_if_needed(raw_text_body, raw_html_body, raw_attachments)

      has_attachments = map_size(attachments) > 0

      # Check if this is actually an inbound email (TO elektrine.com addresses)
      is_outbound = InboundRouting.outbound_email?(from, to)
      is_loopback = InboundRouting.loopback_email?(from, to, subject)

      if is_outbound do
        {:ok, %{id: "skipped-outbound", message_id: message_id}}
      else
        # Check if this is a recently sent email that's looping back
        if is_loopback do
          {:ok, %{id: "skipped-loopback", message_id: message_id}}
        else
          # Find existing mailbox - no automatic creation
          rcpt_to = params["rcpt_to"]

          case InboundRouting.resolve_recipient_mailbox(to, rcpt_to) do
            {:forward_external, target_email, alias_email} ->
              # Handle external forwarding for Haraka email

              # Create and sanitize email data for forwarding
              # Use the SAME sanitization as regular incoming emails for security
              email_data =
                %{
                  "from" => from,
                  "subject" => subject,
                  "text_body" => text_body,
                  "html_body" => html_body,
                  "attachments" => attachments
                }
                |> sanitize_haraka_email_data()

              # Forward the email using the alias email as the from address
              forward_started_at = System.monotonic_time(:millisecond)

              case Elektrine.Email.HarakaClient.forward_email(
                     email_data,
                     target_email,
                     alias_email
                   ) do
                {:ok, _result} ->
                  forward_duration = System.monotonic_time(:millisecond) - forward_started_at

                  Events.email_outbound(:forward, :success, forward_duration, %{
                    route: :haraka,
                    source: :alias_forward
                  })

                  # Record the forwarded message
                  record_forwarded_message_haraka(
                    message_id,
                    from,
                    subject,
                    alias_email,
                    target_email
                  )

                  {:ok, %{id: "forwarded-#{:rand.uniform(1_000_000)}", message_id: message_id}}

                {:error, reason} ->
                  forward_duration = System.monotonic_time(:millisecond) - forward_started_at

                  Events.email_outbound(:forward, :failure, forward_duration, %{
                    route: :haraka,
                    source: :alias_forward,
                    reason: reason
                  })

                  Logger.error(
                    "Failed to forward Haraka email to #{target_email}: #{inspect(reason)}. Dashboard: #{admin_dashboard_url()}"
                  )

                  # Report forwarding failure with details to Sentry
                  Sentry.capture_message("Email forwarding failed",
                    level: :error,
                    extra: %{
                      forward_reason: inspect(reason),
                      alias_email: alias_email,
                      target_email: target_email,
                      original_from: from,
                      subject: subject,
                      forward_duration_ms: forward_duration,
                      dashboard_url: admin_dashboard_url()
                    }
                  )

                  {:error, :forwarding_failed}
              end

            {:ok, mailbox} ->
              # Determine if this is a temporary mailbox from its structure
              is_temporary =
                case mailbox do
                  %{temporary: true} -> true
                  _ -> false
                end

              # Extract spam information from webhook data (now improved)
              spam_info = extract_spam_info_from_webhook(params)
              delivery_signal = classify_delivery_signal(params, from, subject)

              suppression_event =
                build_suppression_event(
                  mailbox,
                  delivery_signal,
                  params,
                  subject,
                  text_body,
                  html_body
                )

              # Double-check spam detection logic
              final_is_spam =
                spam_info.is_spam ||
                  (is_number(spam_info.score) && spam_info.score >= spam_info.threshold)

              # Sanitize and store in database
              # CRITICAL: Sanitize ALL metadata fields to prevent invalid UTF-8 in JSONB
              email_data =
                %{
                  "message_id" => message_id,
                  "from" => from,
                  "to" => to,
                  "subject" => subject,
                  "text_body" => text_body,
                  "html_body" => html_body,
                  "attachments" => attachments,
                  "has_attachments" => has_attachments,
                  "mailbox_id" => mailbox.id,
                  "status" => "received",
                  # Automatically mark as spam based on SpamAssassin analysis
                  "spam" => final_is_spam,
                  "metadata" => %{
                    parsed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
                    temporary: is_temporary,
                    attachment_count: map_size(attachments),
                    format: "haraka",
                    envelope_rcpt_to: sanitize_metadata_field(rcpt_to),
                    envelope_to: sanitize_metadata_field(to),
                    ingest_mode: sanitize_metadata_field(ingest_context["ingest_mode"]),
                    ingest_job_id: sanitize_metadata_field(ingest_context["job_id"]),
                    ingest_received_at: sanitize_metadata_field(ingest_context["received_at"]),
                    ingest_idempotency_key:
                      sanitize_metadata_field(ingest_context["idempotency_key"]),
                    remote_ip: sanitize_metadata_field(ingest_context["remote_ip"]),
                    haraka_id: sanitize_metadata_field(params["id"]),
                    spam_status: sanitize_metadata_field(params["spam_status"]),
                    bounce: sanitize_metadata_field(params["bounce"]),
                    auto_submitted: sanitize_metadata_field(params["auto_submitted"]),
                    size: params["size"],
                    timestamp: sanitize_metadata_field(params["timestamp"]),
                    # SpamAssassin analysis
                    spam_score: spam_info.score,
                    spam_threshold: spam_info.threshold,
                    spam_status_header: sanitize_metadata_field(spam_info.status),
                    spam_report: sanitize_metadata_field(spam_info.report),
                    delivery_signal: sanitize_metadata_field(delivery_signal.signal),
                    is_dsn: delivery_signal.is_dsn,
                    is_feedback_loop: delivery_signal.is_feedback_loop,
                    is_auto_reply: delivery_signal.is_auto_reply,
                    suppression_candidate_reason:
                      sanitize_metadata_field(suppression_event.reason),
                    suppression_candidate_recipients:
                      Enum.map(suppression_event.recipients, &sanitize_metadata_field/1),
                    suppression_candidate_apply: suppression_event.apply?
                  }
                }
                |> sanitize_haraka_email_data()

              # CRITICAL VALIDATION: Ensure Haraka email is going to the correct mailbox
              case InboundRouting.validate_mailbox_route(to, rcpt_to, mailbox) do
                :ok ->
                  # Mark as pre-validated to skip redundant MailboxAdapter validation
                  email_data = Map.put(email_data, "pre_validated", true)

                  # Enhanced deduplication check
                  result =
                    case find_duplicate_message(email_data) do
                      nil ->
                        # No duplicate found, create new message
                        Elektrine.Email.MailboxAdapter.create_message(email_data)

                      existing_message ->
                        # Duplicate found, return existing
                        {:ok, existing_message}
                    end

                  # Broadcast the actual message struct to user topic after creation
                  case result do
                    {:ok, message} ->
                      maybe_apply_suppression(mailbox, suppression_event, params, message_id)

                      if mailbox.user_id do
                        Phoenix.PubSub.broadcast!(
                          Elektrine.PubSub,
                          "user:#{mailbox.user_id}",
                          {:new_email, message}
                        )
                      end

                      result

                    error ->
                      error
                  end

                {:error, reason} ->
                  Logger.error("CRITICAL HARAKA EMAIL ROUTING ERROR: #{reason}")

                  Logger.error(
                    "Attempted to deliver Haraka email TO: #{to} (RCPT_TO: #{rcpt_to}) to WRONG mailbox: #{mailbox.email} (id: #{mailbox.id})"
                  )

                  {:error, :haraka_email_routing_validation_failed}
              end

            {:error, reason} ->
              Logger.error(
                "FAILED to find or create mailbox for to=#{inspect(to)}, rcpt_to=#{inspect(rcpt_to)}"
              )

              Logger.error("Error reason: #{inspect(reason)}")
              Logger.error("This will result in 422 error being returned to Haraka")
              {:error, :no_mailbox}
          end
        end
      end
    rescue
      e ->
        Logger.error("Error processing Haraka email: #{inspect(e)}")
        Logger.error("Stack trace: #{Exception.format_stacktrace()}")

        # Report parsing errors to Sentry
        Sentry.capture_exception(e,
          stacktrace: __STACKTRACE__,
          extra: %{context: "haraka_email_parsing"}
        )

        {:error, :parsing_error}
    catch
      {:security_rejection, reason} ->
        Logger.debug("Security rejection: #{reason}")

        # Send security alert to the owner of the spoofed address
        from = get_header_value(params, "from", "mail_from") || ""
        to = get_header_value(params, "to", "rcpt_to") || ""
        subject = params["subject"] |> extract_from_array()

        Task.start(fn ->
          Elektrine.SecurityAlerts.send_spoofing_alert(from, to, subject)
        end)

        {:error, :security_rejection}
    end
  end

  # Process attachments from Haraka format
  # Normalize attachments to list format
  # Haraka may send attachments as a map with "attachment_0", "attachment_1" keys
  defp normalize_attachments_to_list(nil), do: []
  defp normalize_attachments_to_list(attachments) when is_list(attachments), do: attachments

  defp normalize_attachments_to_list(attachments) when is_map(attachments),
    do: Map.values(attachments)

  defp normalize_attachments_to_list(_), do: []

  defp process_haraka_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {attachment, index}, acc ->
      case process_haraka_attachment(attachment, index) do
        nil -> acc
        processed_attachment -> Map.put(acc, "attachment_#{index}", processed_attachment)
      end
    end)
  end

  defp process_haraka_attachments(_), do: %{}

  # Process a single attachment from Haraka format
  defp process_haraka_attachment(attachment, index) when is_map(attachment) do
    filename = attachment["filename"] || attachment["name"] || "attachment_#{index}"
    content_type = attachment["content_type"] || attachment["type"] || "application/octet-stream"
    size = attachment["size"] || 0
    data = attachment["data"] || attachment["content"] || ""

    # Validate attachment before accepting
    if validate_attachment_safe?(filename, content_type) do
      # The data should be base64 encoded in the Haraka format
      %{
        "filename" => filename,
        "content_type" => content_type,
        "encoding" => "base64",
        "data" => data,
        "size" => size
      }
    else
      Logger.warning("Haraka: Blocked unsafe attachment: #{filename} (#{content_type})")

      Events.email_inbound(:attachment, :failure, nil, %{
        reason: :unsafe_attachment,
        source: :haraka
      })

      nil
    end
  end

  defp process_haraka_attachment(_, _), do: nil

  # Validate if attachment is safe to accept
  defp validate_attachment_safe?(filename, content_type) do
    # Block dangerous file extensions (including archives)
    dangerous_extensions = [
      ".exe",
      ".bat",
      ".sh",
      ".cmd",
      ".com",
      ".scr",
      ".vbs",
      ".js",
      ".jar",
      ".app",
      ".dmg",
      ".apk",
      ".msi",
      ".php",
      ".py",
      ".rb",
      ".zip",
      ".tar",
      ".gz",
      ".7z",
      ".rar"
    ]

    has_dangerous_ext =
      Enum.any?(dangerous_extensions, fn ext ->
        String.ends_with?(String.downcase(filename), ext)
      end)

    # Allow only specific content types
    allowed_types = [
      "image/",
      "application/pdf",
      "application/msword",
      "application/vnd.openxmlformats",
      "application/vnd.ms-excel",
      "text/plain",
      # PGP/GPG encrypted and signed content
      "application/pgp-encrypted",
      "application/pgp-signature",
      "application/pgp-keys",
      # PGP files often come as octet-stream with .asc/.gpg/.pgp extension
      "application/octet-stream"
    ]

    type_allowed =
      Enum.any?(allowed_types, fn allowed -> String.starts_with?(content_type, allowed) end)

    # Special handling for PGP files (.asc, .gpg, .pgp) even if marked as octet-stream
    is_pgp_file = String.ends_with?(String.downcase(filename), [".asc", ".gpg", ".pgp"])

    (!has_dangerous_ext && type_allowed) || is_pgp_file
  end

  # Authentication check using API key
  defp authenticate(conn) do
    # Load API key at runtime
    webhook_api_key =
      System.get_env("HARAKA_INBOUND_API_KEY") || System.get_env("HARAKA_API_KEY")

    if is_nil(webhook_api_key) || webhook_api_key == "" do
      # Security: Fail closed if API key isn't configured
      Logger.error("SECURITY: Webhook authentication configuration error")
      {:error, :unauthorized}
    else
      case List.first(Plug.Conn.get_req_header(conn, "x-api-key")) do
        nil ->
          {:error, :unauthorized}

        provided_key ->
          if Plug.Crypto.secure_compare(provided_key, webhook_api_key) do
            :ok
          else
            {:error, :unauthorized}
          end
      end
    end
  end

  # Get remote IP with proxy header support
  defp get_remote_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end

  # Validate request size to prevent DoS
  defp validate_request_size(conn) do
    content_length_header = List.first(Plug.Conn.get_req_header(conn, "content-length"))

    content_length_result =
      case content_length_header do
        nil ->
          {:ok, 0}

        length_str ->
          case Integer.parse(String.trim(length_str)) do
            {value, ""} when value >= 0 -> {:ok, value}
            _ -> {:error, :invalid_content_length}
          end
      end

    # 25MB limit (matches endpoint.ex)
    max_size = 25 * 1024 * 1024

    case content_length_result do
      {:ok, content_length} when content_length > max_size ->
        Logger.warning("Request too large: #{content_length} bytes (max: #{max_size})")
        {:error, :request_too_large}

      {:ok, _content_length} ->
        :ok

      {:error, :invalid_content_length} ->
        Logger.warning("Invalid content-length header: #{inspect(content_length_header)}")
        {:error, :invalid_content_length}
    end
  end

  # Rate limiting using unified webhook rate limiter
  defp check_rate_limit(ip) do
    WebhookRateLimiter.record_attempt(ip)

    case WebhookRateLimiter.check_rate_limit(ip) do
      {:ok, :allowed} ->
        :ok

      {:error, {:rate_limited, _retry_after, _reason}} ->
        Logger.warning("Webhook rate limit exceeded for IP #{ip}")
        {:error, :rate_limit_exceeded}
    end
  end

  # Helper functions for email processing
  # These could be shared in a common module if needed

  # Extract string from array or return as-is if already string
  defp extract_from_array([value | _]) when is_binary(value), do: value
  defp extract_from_array(value) when is_binary(value), do: value
  defp extract_from_array(_), do: nil

  # Get header value with proper fallback handling
  # Empty strings are treated as missing (unlike Elixir's || which treats "" as truthy)
  defp get_header_value(params, primary_key, fallback_key) do
    primary =
      params[primary_key]
      |> extract_from_array()
      |> decode_header_with_mail_library()
      |> Sanitizer.sanitize_utf8()

    fallback = params[fallback_key]

    cond do
      is_binary(primary) && String.trim(primary) != "" -> primary
      is_binary(fallback) && String.trim(fallback) != "" -> fallback
      true -> nil
    end
  end

  defp extract_subject(params) when is_map(params) do
    primary_subject =
      params["subject"]
      |> extract_from_array()
      |> decode_header_with_mail_library()
      |> Sanitizer.sanitize_utf8()

    header_subject =
      params["headers"]
      |> decode_subject_from_headers()

    choose_cleaner_decoded_text(primary_subject, header_subject)
  end

  defp extract_subject(_), do: ""

  defp decode_subject_from_headers(headers) when is_map(headers) do
    subject_value =
      Enum.find_value(headers, fn
        {key, value} when is_binary(key) ->
          if String.downcase(key) == "subject", do: value

        _ ->
          nil
      end)

    subject_value
    |> extract_from_array()
    |> decode_header_with_mail_library()
    |> Sanitizer.sanitize_utf8()
  end

  defp decode_subject_from_headers(_), do: ""

  defp choose_cleaner_decoded_text(primary, fallback) do
    primary = if(is_binary(primary), do: primary, else: "")
    fallback = if(is_binary(fallback), do: fallback, else: "")

    cond do
      fallback == "" ->
        primary

      primary == "" ->
        fallback

      decoded_text_quality_score(fallback) < decoded_text_quality_score(primary) ->
        fallback

      true ->
        primary
    end
  end

  defp decoded_text_quality_score(text) when is_binary(text) do
    c1_controls = Regex.scan(~r/[\x{0080}-\x{009F}]/u, text) |> length()
    replacement_chars = Regex.scan(~r/�/u, text) |> length()
    mojibake_pairs = Regex.scan(~r/[À-ÿ][\x{0080}-\x{00BF}]/u, text) |> length()
    ascii_marker_noise = Regex.scan(~r/(?:Ã|Â|Å|æ|ç|å)/u, text) |> length()

    c1_controls * 6 + replacement_chars * 8 + mojibake_pairs * 4 + ascii_marker_noise
  end

  defp decoded_text_quality_score(_), do: 0

  # Use the shared email header decoder so webhook and outbound parsing behave the same.
  def decode_mime_header_public(text), do: decode_header_with_mail_library(text)

  defp decode_header_with_mail_library(text), do: HeaderDecoder.decode_mime_header(text)

  # Trust local-domain senders only when the submission is authenticated by Haraka
  # metadata or when it carries a valid internal origin signature generated by us.
  defp trusted_local_sender?(params, from) do
    authenticated_submission?(params) || valid_internal_origin_signature?(params, from)
  end

  defp authenticated_submission?(params) when is_map(params) do
    bool_keys = ["authenticated", "auth", "smtp_authenticated", "is_authenticated"]
    user_keys = ["auth_user", "auth_username", "authenticated_user"]

    has_truthy_boolean =
      Enum.any?(bool_keys, fn key ->
        truthy?(params[key])
      end)

    has_auth_user =
      Enum.any?(user_keys, fn key ->
        value = params[key]
        is_binary(value) && String.trim(value) != ""
      end)

    has_truthy_boolean or has_auth_user
  end

  defp authenticated_submission?(_), do: false

  defp truthy?(value) when value in [true, 1], do: true
  defp truthy?(value) when value in [false, nil, 0], do: false

  defp truthy?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  end

  defp truthy?(_), do: false

  defp valid_internal_origin_signature?(params, from) do
    with secret when is_binary(secret) and secret != "" <-
           System.get_env("HARAKA_INTERNAL_SIGNING_SECRET"),
         headers when is_map(headers) <- params["headers"] || %{},
         "internal" <- header_value(headers, ["x-elektrine-origin", "X-Elektrine-Origin"]),
         ts when is_binary(ts) and ts != "" <-
           header_value(headers, ["x-elektrine-origin-ts", "X-Elektrine-Origin-Ts"]),
         signature when is_binary(signature) and signature != "" <-
           header_value(headers, ["x-elektrine-origin-sig", "X-Elektrine-Origin-Sig"]),
         {timestamp, ""} <- Integer.parse(ts),
         true <- timestamp_fresh?(timestamp) do
      payload = internal_origin_payload(from, ts)
      expected = Base.encode16(:crypto.mac(:hmac, :sha256, secret, payload), case: :lower)
      secure_compare(signature, expected)
    else
      _ -> false
    end
  end

  defp header_value(headers, candidates) do
    Enum.find_value(candidates, fn key ->
      case Map.get(headers, key) do
        value when is_binary(value) -> String.trim(value)
        _ -> nil
      end
    end)
  end

  defp timestamp_fresh?(timestamp) when is_integer(timestamp) do
    now = System.system_time(:second)
    abs(now - timestamp) <= 900
  end

  defp internal_origin_payload(from, ts) do
    clean_from =
      from
      |> InboundRouting.extract_clean_email()
      |> case do
        nil -> ""
        email -> String.downcase(email)
      end

    "internal|#{ts}|#{clean_from}"
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  # Extract spam information from improved Haraka webhook data
  defp extract_spam_info_from_webhook(params) do
    # Try to get spam data directly from webhook (new format)
    spam_score = params["spam_score"] || 0.0
    spam_status = params["spam_status"] || "unknown"
    spam_threshold = params["spam_threshold"] || 5.0
    spam_report = params["spam_report"]
    spam_status_header = params["spam_status_header"]

    # Determine if spam
    is_spam =
      cond do
        is_number(spam_score) and spam_score >= spam_threshold ->
          true

        spam_status == "spam" ->
          true

        is_binary(spam_status_header) and
            String.contains?(String.downcase(spam_status_header), "yes") ->
          true

        true ->
          false
      end

    %{
      score: spam_score,
      status: spam_status_header || spam_status,
      report: spam_report,
      threshold: spam_threshold,
      is_spam: is_spam
    }
  end

  defp classify_delivery_signal(params, from, subject) do
    from_down = (InboundRouting.extract_clean_email(from) || from || "") |> String.downcase()
    subject_down = (subject || "") |> String.downcase()
    auto_submitted = (params["auto_submitted"] || "") |> to_string() |> String.downcase()
    headers = params["headers"] || %{}

    feedback_header? =
      is_map(headers) &&
        Enum.any?(["feedback-type", "Feedback-Type", "x-feedback-id", "X-Feedback-Id"], fn key ->
          case headers[key] do
            value when is_binary(value) and value != "" -> true
            _ -> false
          end
        end)

    is_dsn =
      String.contains?(from_down, "mailer-daemon") ||
        String.contains?(from_down, "postmaster@") ||
        String.contains?(subject_down, "delivery status notification") ||
        String.contains?(subject_down, "mail delivery subsystem") ||
        String.contains?(subject_down, "undelivered") ||
        String.contains?(subject_down, "delivery failure")

    is_feedback_loop =
      feedback_header? ||
        String.contains?(subject_down, "abuse report") ||
        String.contains?(subject_down, "complaint")

    is_auto_reply =
      auto_submitted not in ["", "no"] || String.contains?(subject_down, "out of office")

    signal =
      cond do
        is_feedback_loop -> "feedback_loop"
        is_dsn -> "dsn"
        is_auto_reply -> "auto_reply"
        true -> "normal"
      end

    %{
      signal: signal,
      is_dsn: is_dsn,
      is_feedback_loop: is_feedback_loop,
      is_auto_reply: is_auto_reply
    }
  end

  defp build_suppression_event(mailbox, delivery_signal, params, subject, text_body, html_body) do
    recipients = extract_delivery_signal_recipients(params, text_body, html_body, mailbox)

    cond do
      not auto_suppression_enabled?() ->
        %{apply?: false, reason: nil, source: nil, recipients: []}

      not is_integer(mailbox.user_id) ->
        %{apply?: false, reason: nil, source: nil, recipients: []}

      delivery_signal.is_feedback_loop and recipients != [] ->
        %{apply?: true, reason: "complaint", source: "feedback_loop", recipients: recipients}

      delivery_signal.is_dsn and hard_bounce?(params, subject, text_body, html_body) and
          recipients != [] ->
        %{apply?: true, reason: "hard_bounce", source: "dsn_hard_bounce", recipients: recipients}

      true ->
        %{apply?: false, reason: nil, source: nil, recipients: []}
    end
  end

  defp maybe_apply_suppression(
         %{user_id: user_id},
         %{apply?: true, recipients: recipients, reason: reason, source: source},
         params,
         message_id
       )
       when is_integer(user_id) and is_list(recipients) do
    event_at = DateTime.utc_now()

    results =
      Enum.map(recipients, fn recipient ->
        metadata = %{
          "message_id" => message_id,
          "haraka_id" => params["id"],
          "reason_source" => source,
          "from" => params["from"],
          "subject" => params["subject"]
        }

        case Suppressions.suppress_recipient(user_id, recipient,
               reason: reason,
               source: "haraka_inbound",
               metadata: metadata,
               last_event_at: event_at
             ) do
          {:ok, _suppression} ->
            {:ok, recipient}

          {:error, suppress_reason} ->
            {:error, recipient, suppress_reason}
        end
      end)

    applied = for {:ok, recipient} <- results, do: recipient
    failed = for {:error, recipient, failure_reason} <- results, do: {recipient, failure_reason}

    if applied != [] do
      Events.email_inbound(:suppression, :applied, nil, %{
        source: :haraka,
        user_id: user_id,
        reason: reason,
        count: length(applied)
      })
    end

    if failed != [] do
      Logger.warning(
        "Failed to apply suppression entries for user #{user_id}: #{inspect(failed)}"
      )

      Events.email_inbound(:suppression, :failure, nil, %{
        source: :haraka,
        user_id: user_id,
        reason: reason,
        count: length(failed)
      })
    end

    :ok
  end

  defp maybe_apply_suppression(_mailbox, _suppression_event, _params, _message_id), do: :ok

  defp auto_suppression_enabled? do
    case Application.get_env(:elektrine, :email_auto_suppression, true) do
      true -> true
      false -> false
      _ -> false
    end
  end

  defp hard_bounce?(params, subject, text_body, html_body) do
    headers_blob =
      params["headers"]
      |> normalize_headers()
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{inspect(v)}" end)

    combined =
      [subject, text_body, strip_html_tags(html_body), headers_blob]
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")

    combined_down = String.downcase(combined)

    status_codes =
      Regex.scan(~r/\b([245]\.\d{1,3}\.\d{1,3})\b/, combined, capture: :all_but_first)
      |> List.flatten()

    cond do
      Enum.any?(status_codes, &String.starts_with?(&1, "5.")) ->
        true

      Enum.any?(status_codes, &String.starts_with?(&1, "4.")) ->
        false

      String.contains?(combined_down, " smtp; 550") or String.contains?(combined_down, " 550 ") ->
        true

      Enum.any?(@hard_bounce_indicators, &String.contains?(combined_down, &1)) ->
        true

      Enum.any?(@soft_bounce_indicators, &String.contains?(combined_down, &1)) ->
        false

      true ->
        false
    end
  end

  defp extract_delivery_signal_recipients(params, text_body, html_body, mailbox) do
    headers = normalize_headers(params["headers"])

    structured_values = [
      params["failed_recipients"],
      params["final_recipient"],
      params["original_recipient"],
      params["recipient"],
      get_case_insensitive(headers, "x-failed-recipients"),
      get_case_insensitive(headers, "final-recipient"),
      get_case_insensitive(headers, "original-recipient"),
      get_case_insensitive(headers, "recipient")
    ]

    structured_emails =
      structured_values
      |> Enum.flat_map(&extract_emails_from_value/1)

    body_blob =
      [text_body, strip_html_tags(html_body)]
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")

    hinted_emails =
      extract_dsn_emails(body_blob)
      |> case do
        [] ->
          extract_emails_from_value(body_blob)

        values ->
          values
      end

    candidates = if structured_emails != [], do: structured_emails, else: hinted_emails

    mailbox_email =
      mailbox.email
      |> InboundRouting.extract_clean_email()
      |> case do
        nil -> nil
        email -> String.downcase(email)
      end

    candidates
    |> Enum.map(&InboundRouting.extract_clean_email/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&internal_email?/1)
    |> Enum.reject(&(&1 == mailbox_email))
    |> Enum.uniq()
  end

  defp extract_dsn_emails(blob) when is_binary(blob) do
    regexes = [
      ~r/(?:Final-Recipient|Original-Recipient)\s*:\s*[^;\n]*;\s*([A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})/i,
      ~r/X-Failed-Recipients\s*:\s*([A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})/i,
      ~r/Recipient\s*:\s*([A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})/i
    ]

    regexes
    |> Enum.flat_map(fn regex ->
      Regex.scan(regex, blob, capture: :all_but_first) |> List.flatten()
    end)
    |> Enum.uniq()
  end

  defp extract_dsn_emails(_), do: []

  defp extract_emails_from_value(value) when is_binary(value) do
    Regex.scan(~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, value, capture: :all_but_first)
    |> List.flatten()
  end

  defp extract_emails_from_value(value) when is_list(value) do
    Enum.flat_map(value, &extract_emails_from_value/1)
  end

  defp extract_emails_from_value(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.flat_map(&extract_emails_from_value/1)
  end

  defp extract_emails_from_value(_), do: []

  defp normalize_headers(headers) when is_map(headers), do: headers
  defp normalize_headers(_), do: %{}

  defp get_case_insensitive(map, key) when is_map(map) and is_binary(key) do
    key_down = String.downcase(key)

    Enum.find_value(map, fn
      {map_key, value} when is_binary(map_key) ->
        if String.downcase(map_key) == key_down, do: value

      _ ->
        nil
    end)
  end

  defp get_case_insensitive(_, _), do: nil

  defp strip_html_tags(value) when is_binary(value) do
    value
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&nbsp;", " ")
  end

  defp strip_html_tags(_), do: ""

  defp internal_email?(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [_local, domain] ->
        domain in supported_domains()

      _ ->
        false
    end
  end

  defp internal_email?(_), do: false

  defp supported_domains do
    Application.get_env(:elektrine, :email)[:supported_domains] || ["elektrine.com", "z.org"]
  end

  # Get appropriate HTTP status code for email bouncing
  defp get_bounce_status(reason) do
    case reason do
      :no_mailbox ->
        # 404 Not Found - causes Haraka to bounce (maps to SMTP 550)
        {404, "Mailbox does not exist"}

      :invalid_email ->
        # 400 Bad Request - invalid recipient address (maps to SMTP 550)
        {400, "Invalid recipient address"}

      :haraka_email_routing_validation_failed ->
        # 404 Not Found - mailbox unavailable (maps to SMTP 550)
        {404, "Mailbox routing validation failed"}

      :security_rejection ->
        # 403 Forbidden - rejected for security reasons (spam, spoofing, etc.)
        # Note: SMTP uses 550, but HTTP doesn't have that code, so we use 403
        {403, "Message rejected for security reasons"}

      :storage_limit_exceeded ->
        # 507 Insufficient Storage - temporary failure, can retry (maps to SMTP 552)
        {507, "Mailbox storage limit exceeded"}

      _ ->
        # 503 Service Unavailable - temporary failure, allows retry (maps to SMTP 451)
        {503, "Temporary server error: #{inspect(reason)}"}
    end
  end

  # Enhanced duplicate message detection - should be shared
  defp find_duplicate_message(email_data) do
    import Ecto.Query
    alias Elektrine.Email.Message
    alias Elektrine.Repo

    envelope_rcpt_to = get_in(email_data, ["metadata", "envelope_rcpt_to"])

    # Check by message ID first
    by_message_id =
      Message
      |> where(
        [m],
        m.message_id == ^email_data["message_id"] and m.mailbox_id == ^email_data["mailbox_id"]
      )
      |> Repo.one()

    if by_message_id do
      by_message_id
    else
      # Check for near-duplicates by subject, from, and time
      five_minutes_ago = DateTime.utc_now() |> DateTime.add(-300, :second)

      near_duplicate_query =
        Message
        |> where([m], m.mailbox_id == ^email_data["mailbox_id"])
        |> where([m], m.subject == ^email_data["subject"])
        |> where([m], m.from == ^email_data["from"])
        |> where([m], m.inserted_at > ^five_minutes_ago)
        |> maybe_filter_by_envelope_rcpt(envelope_rcpt_to)
        |> limit(1)

      Repo.one(near_duplicate_query)
    end
  end

  defp maybe_filter_by_envelope_rcpt(query, envelope_rcpt_to)
       when is_binary(envelope_rcpt_to) and envelope_rcpt_to != "" do
    import Ecto.Query, only: [where: 3]

    where(
      query,
      [m],
      fragment(
        "lower(coalesce(?->>'envelope_rcpt_to', '')) = lower(?)",
        m.metadata,
        ^envelope_rcpt_to
      )
    )
  end

  defp maybe_filter_by_envelope_rcpt(query, _), do: query

  # Record a forwarded message to the database for tracking
  defp record_forwarded_message_haraka(
         message_id,
         from_address,
         subject,
         original_recipient,
         final_recipient
       ) do
    # Get alias record for tracking
    alias_record = Elektrine.Email.get_alias_by_email(original_recipient)

    attrs = %{
      message_id: message_id,
      from_address: from_address,
      subject: subject,
      original_recipient: original_recipient,
      final_recipient: final_recipient,
      forwarding_chain: %{
        hops: [
          %{
            "from" => original_recipient,
            "to" => final_recipient,
            "alias_id" => alias_record && alias_record.id
          }
        ]
      },
      total_hops: 1,
      alias_id: alias_record && alias_record.id
    }

    case Repo.insert(ForwardedMessage.changeset(%ForwardedMessage{}, attrs)) do
      {:ok, _record} ->
        :ok

      {:error, _changeset} ->
        :error
    end
  end

  # Sanitize metadata fields to ensure they don't contain invalid UTF-8
  # Metadata is stored as JSONB in PostgreSQL which requires valid UTF-8
  defp sanitize_metadata_field(value) when is_binary(value) do
    Sanitizer.sanitize_utf8(value)
  end

  defp sanitize_metadata_field(value), do: value

  # Apply inbound payload sanitization exactly once before forwarding or persistence.
  defp sanitize_haraka_email_data(email_data) when is_map(email_data) do
    email_data
    |> Sanitizer.sanitize_incoming_email()
    |> ensure_all_utf8_valid()
  end

  # Ensure ALL string fields in email_data are valid UTF-8 (deep validation)
  # This is a final safety check before database insertion
  defp ensure_all_utf8_valid(email_data) when is_map(email_data) do
    email_data
    |> Enum.map(fn {key, value} ->
      {key, ensure_value_utf8_valid(value)}
    end)
    |> Map.new()
  end

  defp ensure_value_utf8_valid(value) when is_binary(value) do
    # Double-check every string is valid UTF-8
    if String.valid?(value) do
      value
    else
      # Should never happen if sanitization worked, but just in case
      require Logger

      Logger.warning(
        "Found invalid UTF-8 after sanitization, forcing valid: #{inspect(value, limit: 50)}"
      )

      Sanitizer.sanitize_utf8(value)
    end
  end

  defp ensure_value_utf8_valid(value) when is_map(value) do
    # Recursively validate nested maps (like metadata)
    value
    |> Enum.map(fn {k, v} -> {k, ensure_value_utf8_valid(v)} end)
    |> Map.new()
  end

  defp ensure_value_utf8_valid(value) when is_list(value) do
    # Handle lists
    Enum.map(value, &ensure_value_utf8_valid/1)
  end

  defp ensure_value_utf8_valid(value), do: value

  # Reconstruct PGP/MIME encrypted emails from attachments
  # PGP/MIME emails (RFC 3156) have the encrypted content as attachments, not in text_body
  defp reconstruct_pgp_mime_if_needed(text_body, html_body, attachments)
       when is_list(attachments) do
    # Check if this looks like a PGP/MIME email
    # Use Map.get to safely access fields - attachments may contain non-map items
    has_pgp_mime_attachments =
      Enum.any?(attachments, fn att ->
        if is_map(att) do
          ct = Map.get(att, "content_type") || Map.get(att, "mime_type") || ""

          String.contains?(ct, "application/pgp-encrypted") ||
            String.contains?(ct, "application/pgp-signature")
        else
          false
        end
      end)

    if has_pgp_mime_attachments do
      # PGP/MIME structure (RFC 3156):
      # Part 1: application/pgp-encrypted with "Version: 1"
      # Part 2: application/octet-stream with actual encrypted PGP message

      # Find the encrypted data attachment (the one with actual content, not version)
      encrypted_attachment =
        Enum.find(attachments, fn att ->
          if is_map(att) do
            ct = Map.get(att, "content_type") || Map.get(att, "mime_type") || ""
            data = Map.get(att, "content") || Map.get(att, "data") || ""

            # Skip the version part (very small, just "Version: 1")
            # Look for octet-stream with substantial data
            # Or explicitly named encrypted.asc
            (String.contains?(ct, "application/octet-stream") && byte_size(data) > 50) ||
              (String.ends_with?(Map.get(att, "filename") || "", ".asc") && byte_size(data) > 50)
          else
            false
          end
        end)

      case encrypted_attachment do
        nil ->
          {text_body, html_body, process_haraka_attachments(attachments)}

        att when is_map(att) ->
          # Decode the encrypted content from base64 (Haraka sends as base64)
          encrypted_data =
            case Map.get(att, "content") || Map.get(att, "data") do
              nil ->
                ""

              data when is_binary(data) ->
                # Haraka sends attachment content as base64
                case Base.decode64(data) do
                  {:ok, decoded} ->
                    decoded

                  :error ->
                    data
                end
            end

          # Ensure the encrypted data is valid UTF-8 (should be, it's base64)
          safe_encrypted_data = ensure_safe_utf8(encrypted_data)

          # Check if the encrypted data already has PGP armor headers
          reconstructed_text =
            if String.contains?(safe_encrypted_data, "-----BEGIN PGP") do
              # Already has armor, use as-is
              safe_encrypted_data
            else
              # Need to add armor headers
              "-----BEGIN PGP MESSAGE-----\n\n#{safe_encrypted_data}\n-----END PGP MESSAGE-----"
            end

          # Return reconstructed body, keep non-PGP attachments as regular attachments
          other_attachments =
            Enum.reject(attachments, fn a ->
              if is_map(a) do
                ct = Map.get(a, "content_type", "")

                String.contains?(ct, "application/pgp-encrypted") ||
                  String.contains?(ct, "application/pgp-signature") ||
                  String.contains?(ct, "application/octet-stream")
              else
                false
              end
            end)

          {reconstructed_text, html_body, process_haraka_attachments(other_attachments)}

        _ ->
          # Non-map attachment found, skip PGP processing
          {text_body, html_body, process_haraka_attachments(attachments)}
      end
    else
      # Not a PGP/MIME email, process normally
      {text_body, html_body, process_haraka_attachments(attachments)}
    end
  end

  defp reconstruct_pgp_mime_if_needed(text_body, html_body, _attachments) do
    # Fallback for non-list attachments
    {text_body, html_body, %{}}
  end

  defp admin_dashboard_url do
    "#{ElektrineWeb.Endpoint.url()}/pripyat"
  end

  # Ensure string is safe for UTF-8 operations (prevents crashes)
  # This is a lightweight check BEFORE full sanitization
  # CRITICAL: Does NOT modify valid UTF-8 content in any way
  # Only fixes invalid UTF-8 by replacing bad bytes with U+FFFD
  defp ensure_safe_utf8(content) when is_binary(content) do
    if String.valid?(content) do
      # Valid UTF-8 - return as-is with NO modifications
      # This preserves PGP armor and all other content exactly
      content
    else
      # Invalid UTF-8 detected - replace ONLY the invalid bytes
      # Do NOT call fix_common_encoding_issues or any regex!
      require Logger

      Logger.warning(
        "Invalid UTF-8 detected in email body from Haraka - replacing invalid bytes only"
      )

      # Replace invalid UTF-8 sequences without modifying valid content
      String.codepoints(content)
      |> Enum.map(fn codepoint ->
        if String.valid?(codepoint) do
          codepoint
        else
          # U+FFFD replacement character
          "�"
        end
      end)
      |> Enum.map_join("", & &1)
    end
  end

  defp ensure_safe_utf8(nil), do: ""
  defp ensure_safe_utf8(_), do: ""
end
