defmodule Elektrine.UserNotifier do
  @moduledoc """
  Delivers user notifications via email.
  """

  import Swoosh.Email

  @doc """
  Deliver password reset instructions to the given user.
  """
  def password_reset_instructions(user, reset_token) do
    if user.recovery_email do
      new()
      |> to(user.recovery_email)
      |> from(system_from_email())
      |> subject("Reset your Elektrine password")
      |> html_body(password_reset_html_body(user, reset_token))
      |> text_body(password_reset_text_body(user, reset_token))
      |> header("List-Id", "<elektrine-password-reset.elektrine.com>")
    else
      raise ArgumentError, "User #{user.username} has no recovery email set"
    end
  end

  defp password_reset_html_body(user, reset_token) do
    reset_url = ElektrineWeb.Endpoint.url() <> "/password/reset/#{reset_token}"

    """
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
                        <h1 style="margin: 0; color: #a855f7; font-size: 24px; font-weight: 600;">Password Reset Request</h1>
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
                        <p style="margin: 0 0 30px 0; color: #d1d5db; font-size: 16px; line-height: 1.6;">
                          You recently requested to reset your password for your Elektrine account. Click the button below to reset it:
                        </p>

                        <!-- Button -->
                        <table role="presentation" cellpadding="0" cellspacing="0" style="margin: 30px 0;">
                          <tr>
                            <td style="background-color: #a855f7; border-radius: 8px;">
                              <a href="#{reset_url}" style="display: inline-block; padding: 14px 28px; color: #ffffff; text-decoration: none; font-size: 16px; font-weight: 600;">
                                Reset Your Password
                              </a>
                            </td>
                          </tr>
                        </table>

                        <p style="margin: 0 0 15px 0; color: #9ca3af; font-size: 14px; line-height: 1.6;">
                          If the button doesn't work, you can copy and paste the following link into your browser:
                        </p>

                        <!-- URL Box -->
                        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin: 0 0 20px 0;">
                          <tr>
                            <td style="background-color: #171717; padding: 12px 16px; border-radius: 6px; word-break: break-all;">
                              <a href="#{reset_url}" style="color: #a855f7; font-size: 14px; text-decoration: none;">#{reset_url}</a>
                            </td>
                          </tr>
                        </table>

                        <p style="margin: 0 0 20px 0; color: #f97316; font-size: 14px; font-weight: 600; line-height: 1.6;">
                          This link will expire in 1 hour for security reasons.
                        </p>
                        <p style="margin: 0; color: #9ca3af; font-size: 14px; line-height: 1.6;">
                          If you didn't request a password reset, you can safely ignore this email. Your password will remain unchanged.
                        </p>
                      </td>
                    </tr>
                  </table>

                  <!-- Footer -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding-top: 30px; border-top: 1px solid #1f1f1f;">
                        <p style="margin: 0; color: #6b7280; font-size: 12px;">
                          This is an automated message from Elektrine. Please do not reply to this email.
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

  defp password_reset_text_body(user, reset_token) do
    reset_url = ElektrineWeb.Endpoint.url() <> "/password/reset/#{reset_token}"

    """
    Password Reset Request

    Hello #{user.username},

    You recently requested to reset your password for your Elektrine account. 

    To reset your password, visit the following link:
    #{reset_url}

    This link will expire in 1 hour for security reasons.

    If you didn't request a password reset, you can safely ignore this email. Your password will remain unchanged.

    This is an automated message from Elektrine. Please do not reply to this email.
    """
  end

  # Get system from email based on configuration
  defp system_from_email do
    # Default to elektrine.com domain
    {"Elektrine", "noreply@elektrine.com"}
  end
end
