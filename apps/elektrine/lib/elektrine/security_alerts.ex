defmodule Elektrine.SecurityAlerts do
  @moduledoc """
  Sends security alerts to users via their mailbox and recovery email.
  Security alerts are always sent regardless of notification preferences.
  """

  require Logger
  import Swoosh.Email

  alias Elektrine.Accounts
  alias Elektrine.Email.MailboxAdapter

  # Rate limit: 1 alert per type per user per hour
  @rate_limit_seconds 3600

  @doc """
  Send a spoofing alert when someone tries to send email from a user's address.
  """
  def send_spoofing_alert(spoofed_address, recipient_address, subject) do
    # Find the user who owns the spoofed address
    case find_owner(spoofed_address) do
      {:ok, user} ->
        # Check rate limit
        cache_key = "security_alert:spoofing:#{user.id}:#{spoofed_address}"

        if rate_limited?(cache_key) do
          Logger.debug("Rate limited spoofing alert for #{spoofed_address}")
          {:ok, :rate_limited}
        else
          # Send alerts
          send_spoofing_alert_to_user(user, spoofed_address, recipient_address, subject)
          set_rate_limit(cache_key)
          {:ok, :sent}
        end

      {:error, :not_found} ->
        Logger.debug("No owner found for spoofed address: #{spoofed_address}")
        {:error, :no_owner}
    end
  end

  defp send_spoofing_alert_to_user(user, spoofed_address, recipient_address, subject) do
    # 1. Send to user's mailbox
    send_to_mailbox(user, spoofed_address, recipient_address, subject)

    # 2. Send to recovery email if set
    if user.recovery_email do
      send_to_recovery_email(user, spoofed_address, recipient_address, subject)
    end
  end

  defp send_to_mailbox(user, spoofed_address, recipient_address, subject) do
    # Get user's primary mailbox
    case Elektrine.Email.get_user_mailbox(user.id) do
      %{id: _mailbox_id, email: _mailbox_email} = mailbox ->
        alert_subject = "Security Alert: Email spoofing attempt detected"

        html_body = spoofing_alert_html(user, spoofed_address, recipient_address, subject)
        text_body = spoofing_alert_text(user, spoofed_address, recipient_address, subject)

        message_attrs = %{
          "message_id" =>
            "security-alert-#{:rand.uniform(1_000_000)}-#{System.system_time(:millisecond)}",
          "from" => "Elektrine Security <security@elektrine.com>",
          "to" => mailbox.email,
          "subject" => alert_subject,
          "text_body" => text_body,
          "html_body" => html_body,
          "mailbox_id" => mailbox.id,
          "status" => "received",
          "spam" => false,
          "metadata" => %{
            "type" => "security_alert",
            "alert_type" => "spoofing",
            "spoofed_address" => spoofed_address
          }
        }

        case MailboxAdapter.create_message(message_attrs) do
          {:ok, _message} ->
            Logger.info("Sent spoofing alert to mailbox for user #{user.username}")
            :ok

          {:error, reason} ->
            Logger.error("Failed to send spoofing alert to mailbox: #{inspect(reason)}")
            :error
        end

      nil ->
        Logger.warning("User #{user.username} has no mailbox for security alert")
        :error
    end
  end

  defp send_to_recovery_email(user, spoofed_address, recipient_address, subject) do
    alert_subject = "Security Alert: Email spoofing attempt detected"

    email =
      new()
      |> to(user.recovery_email)
      |> from({"Elektrine Security", "security@elektrine.com"})
      |> subject(alert_subject)
      |> html_body(spoofing_alert_html(user, spoofed_address, recipient_address, subject))
      |> text_body(spoofing_alert_text(user, spoofed_address, recipient_address, subject))

    case Elektrine.Mailer.deliver(email) do
      {:ok, _} ->
        Logger.info("Sent spoofing alert to recovery email for user #{user.username}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to send spoofing alert to recovery email: #{inspect(reason)}")
        :error
    end
  end

  defp find_owner(email_address) do
    clean_email = email_address |> String.trim() |> String.downcase()

    # Check if it's a mailbox
    case Elektrine.Email.get_mailbox_by_email(clean_email) do
      %{user_id: user_id} when not is_nil(user_id) ->
        try do
          {:ok, Accounts.get_user!(user_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        # Check if it's an alias
        case Elektrine.Email.get_alias_by_email(clean_email) do
          %{user_id: user_id} when not is_nil(user_id) ->
            try do
              {:ok, Accounts.get_user!(user_id)}
            rescue
              Ecto.NoResultsError -> {:error, :not_found}
            end

          _ ->
            {:error, :not_found}
        end
    end
  end

  # Rate limiting using Cachex
  defp rate_limited?(cache_key) do
    case Cachex.get(:security_alerts_cache, cache_key) do
      {:ok, nil} -> false
      {:ok, _} -> true
      _ -> false
    end
  end

  defp set_rate_limit(cache_key) do
    Cachex.put(:security_alerts_cache, cache_key, true, ttl: :timer.seconds(@rate_limit_seconds))
  end

  # Email templates
  defp spoofing_alert_html(user, spoofed_address, recipient_address, original_subject) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%B %d, %Y at %H:%M UTC")

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <meta name="color-scheme" content="dark">
    </head>
    <body style="margin: 0; padding: 0; background-color: #000000; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #000000;">
        <tr>
          <td align="center" style="padding: 40px 20px;">
            <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width: 600px; background-color: #0a0a0a; border: 1px solid #dc2626; border-radius: 12px;">
              <tr>
                <td style="padding: 40px;">
                  <!-- Header -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding-bottom: 30px; border-bottom: 1px solid #1f1f1f;">
                        <h1 style="margin: 0; color: #dc2626; font-size: 24px; font-weight: 600;">Security Alert</h1>
                        <p style="margin: 10px 0 0 0; color: #f87171; font-size: 14px;">Email Spoofing Attempt Detected</p>
                      </td>
                    </tr>
                  </table>

                  <!-- Content -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding: 30px 0;">
                        <p style="margin: 0 0 20px 0; color: #e5e5e5; font-size: 16px; line-height: 1.6;">
                          Hello #{user.username},
                        </p>
                        <p style="margin: 0 0 20px 0; color: #d1d5db; font-size: 16px; line-height: 1.6;">
                          We blocked an email that attempted to impersonate your address. Someone from outside Elektrine tried to send an email pretending to be from your account.
                        </p>

                        <!-- Details Box -->
                        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin: 20px 0; background-color: #171717; border-radius: 8px;">
                          <tr>
                            <td style="padding: 20px;">
                              <p style="margin: 0 0 12px 0; color: #9ca3af; font-size: 12px; text-transform: uppercase; letter-spacing: 1px;">Attempt Details</p>
                              <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                                <tr>
                                  <td style="padding: 8px 0; color: #9ca3af; font-size: 14px; width: 120px;">Spoofed From:</td>
                                  <td style="padding: 8px 0; color: #f87171; font-size: 14px; font-weight: 600;">#{spoofed_address}</td>
                                </tr>
                                <tr>
                                  <td style="padding: 8px 0; color: #9ca3af; font-size: 14px;">Sent To:</td>
                                  <td style="padding: 8px 0; color: #e5e5e5; font-size: 14px;">#{recipient_address}</td>
                                </tr>
                                <tr>
                                  <td style="padding: 8px 0; color: #9ca3af; font-size: 14px;">Subject:</td>
                                  <td style="padding: 8px 0; color: #e5e5e5; font-size: 14px;">#{original_subject || "(No subject)"}</td>
                                </tr>
                                <tr>
                                  <td style="padding: 8px 0; color: #9ca3af; font-size: 14px;">Time:</td>
                                  <td style="padding: 8px 0; color: #e5e5e5; font-size: 14px;">#{timestamp}</td>
                                </tr>
                              </table>
                            </td>
                          </tr>
                        </table>

                        <p style="margin: 20px 0; color: #22c55e; font-size: 14px; font-weight: 600;">
                          This email was blocked and was not delivered.
                        </p>

                        <p style="margin: 20px 0 0 0; color: #9ca3af; font-size: 14px; line-height: 1.6;">
                          <strong style="color: #e5e5e5;">What should you do?</strong><br>
                          No action is required. This is an informational alert. The spoofed email was automatically blocked by our security systems.
                        </p>

                        <p style="margin: 20px 0 0 0; color: #9ca3af; font-size: 14px; line-height: 1.6;">
                          If you see multiple alerts like this, someone may be targeting your identity. Consider enabling additional security measures in your account settings.
                        </p>
                      </td>
                    </tr>
                  </table>

                  <!-- Footer -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding-top: 30px; border-top: 1px solid #1f1f1f;">
                        <p style="margin: 0; color: #6b7280; font-size: 12px;">
                          This is an automated security alert from Elektrine. You cannot unsubscribe from security alerts.
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
  end

  defp spoofing_alert_text(user, spoofed_address, recipient_address, original_subject) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%B %d, %Y at %H:%M UTC")

    """
    SECURITY ALERT: Email Spoofing Attempt Detected

    Hello #{user.username},

    We blocked an email that attempted to impersonate your address. Someone from outside Elektrine tried to send an email pretending to be from your account.

    ATTEMPT DETAILS:
    - Spoofed From: #{spoofed_address}
    - Sent To: #{recipient_address}
    - Subject: #{original_subject || "(No subject)"}
    - Time: #{timestamp}

    This email was blocked and was not delivered.

    WHAT SHOULD YOU DO?
    No action is required. This is an informational alert. The spoofed email was automatically blocked by our security systems.

    If you see multiple alerts like this, someone may be targeting your identity. Consider enabling additional security measures in your account settings.

    ---
    This is an automated security alert from Elektrine. You cannot unsubscribe from security alerts.
    """
  end
end
