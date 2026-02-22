defmodule Elektrine.Accounts.RecoveryEmailVerification do
  @moduledoc """
  Handles recovery email verification.

  Recovery emails must be verified before they can be used for password resets.
  This also handles lifting email restrictions for users who hit rate limits.
  """

  import Swoosh.Email
  alias Elektrine.Accounts.User
  alias Elektrine.Repo
  require Logger

  @token_validity_hours 24

  @doc """
  Sends a verification email to the user's recovery email address.
  Works for both new recovery emails and restricted accounts.
  Returns {:ok, user} or {:error, reason}.
  """
  def send_verification_email(user_id, opts \\ []) do
    # Option to force resend even if already verified
    force_resend = Keyword.get(opts, :force, false)

    case Repo.get(User, user_id) do
      nil ->
        {:error, :user_not_found}

      user ->
        cond do
          is_nil(user.recovery_email) || user.recovery_email == "" ->
            {:error, :no_recovery_email}

          user.recovery_email_verified && !force_resend && !user.email_sending_restricted ->
            {:error, :already_verified}

          true ->
            do_send_verification_email(user)
        end
    end
  end

  defp do_send_verification_email(user) do
    token = generate_token()

    case update_verification_token(user, token) do
      {:ok, updated_user} ->
        # Send the email with appropriate message based on restriction status
        send_email(updated_user, token, user.email_sending_restricted)
        {:ok, updated_user}

      {:error, _} = error ->
        error
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp update_verification_token(user, token) do
    user
    |> Ecto.Changeset.change(%{
      recovery_email_verification_token: token,
      recovery_email_verification_sent_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  defp send_email(user, token, is_restricted) do
    verify_url = ElektrineWeb.Endpoint.url() <> "/verify-recovery-email?token=#{token}"

    app_name = Application.get_env(:elektrine, :app_name, "Elektrine")

    {subject, text_body, html_body} =
      if is_restricted do
        build_restriction_email(user, verify_url, app_name)
      else
        build_verification_email(user, verify_url, app_name)
      end

    # Use Swoosh email directly via Mailer
    new()
    |> to(user.recovery_email)
    |> from({"Elektrine", "noreply@elektrine.com"})
    |> subject(subject)
    |> html_body(html_body)
    |> text_body(text_body)
    |> Elektrine.Mailer.deliver()

    Logger.info("Sent recovery email verification to #{user.recovery_email} for user #{user.id}")
  end

  defp build_verification_email(user, verify_url, app_name) do
    subject = "Verify your recovery email address"

    text_body = """
    Hi #{user.username},

    Please verify your recovery email address by clicking the link below:

    #{verify_url}

    This link will expire in #{@token_validity_hours} hours.

    Once verified, this email can be used for password resets and account recovery.

    If you did not add this recovery email, you can safely ignore this message.

    - The #{app_name} Team
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
                        <h1 style="margin: 0; color: #a855f7; font-size: 24px; font-weight: 600;">Verify Your Recovery Email</h1>
                      </td>
                    </tr>
                  </table>

                  <!-- Content -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding: 30px 0;">
                        <p style="margin: 0 0 20px 0; color: #e5e5e5; font-size: 16px; line-height: 1.6;">
                          Hi #{user.username},
                        </p>
                        <p style="margin: 0 0 30px 0; color: #d1d5db; font-size: 16px; line-height: 1.6;">
                          Please verify your recovery email address by clicking the button below:
                        </p>

                        <!-- Button -->
                        <table role="presentation" cellpadding="0" cellspacing="0" style="margin: 30px 0;">
                          <tr>
                            <td style="background-color: #a855f7; border-radius: 8px;">
                              <a href="#{verify_url}" style="display: inline-block; padding: 14px 28px; color: #ffffff; text-decoration: none; font-size: 16px; font-weight: 600;">
                                Verify Email Address
                              </a>
                            </td>
                          </tr>
                        </table>

                        <p style="margin: 0 0 20px 0; color: #9ca3af; font-size: 14px; line-height: 1.6;">
                          This link will expire in #{@token_validity_hours} hours.
                        </p>
                        <p style="margin: 0 0 20px 0; color: #d1d5db; font-size: 16px; line-height: 1.6;">
                          Once verified, this email can be used for password resets and account recovery.
                        </p>
                        <p style="margin: 0; color: #9ca3af; font-size: 14px; line-height: 1.6;">
                          If you did not add this recovery email, you can safely ignore this message.
                        </p>
                      </td>
                    </tr>
                  </table>

                  <!-- Footer -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding-top: 30px; border-top: 1px solid #1f1f1f;">
                        <p style="margin: 0; color: #6b7280; font-size: 12px;">
                          - The #{app_name} Team
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

    {subject, text_body, html_body}
  end

  defp build_restriction_email(user, verify_url, app_name) do
    subject = "Verify your recovery email to restore email sending"

    text_body = """
    Hi #{user.username},

    Your email sending privileges have been temporarily restricted due to rate limit violations.

    To restore your ability to send emails, please verify your recovery email by clicking the link below:

    #{verify_url}

    This link will expire in #{@token_validity_hours} hours.

    If you did not request this or believe this is an error, please contact support.

    - The #{app_name} Team
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
                        <h1 style="margin: 0; color: #f97316; font-size: 24px; font-weight: 600;">Restore Email Sending</h1>
                      </td>
                    </tr>
                  </table>

                  <!-- Alert Box -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding: 20px 0;">
                        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #1c1917; border: 1px solid #f97316; border-radius: 8px;">
                          <tr>
                            <td style="padding: 16px;">
                              <p style="margin: 0; color: #fed7aa; font-size: 14px; line-height: 1.6;">
                                Your email sending privileges have been temporarily restricted due to rate limit violations.
                              </p>
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
                          Hi #{user.username},
                        </p>
                        <p style="margin: 0 0 30px 0; color: #d1d5db; font-size: 16px; line-height: 1.6;">
                          To restore your ability to send emails, please verify your recovery email by clicking the button below:
                        </p>

                        <!-- Button -->
                        <table role="presentation" cellpadding="0" cellspacing="0" style="margin: 30px 0;">
                          <tr>
                            <td style="background-color: #a855f7; border-radius: 8px;">
                              <a href="#{verify_url}" style="display: inline-block; padding: 14px 28px; color: #ffffff; text-decoration: none; font-size: 16px; font-weight: 600;">
                                Verify Recovery Email
                              </a>
                            </td>
                          </tr>
                        </table>

                        <p style="margin: 0 0 20px 0; color: #9ca3af; font-size: 14px; line-height: 1.6;">
                          This link will expire in #{@token_validity_hours} hours.
                        </p>
                        <p style="margin: 0; color: #9ca3af; font-size: 14px; line-height: 1.6;">
                          If you did not request this or believe this is an error, please contact support.
                        </p>
                      </td>
                    </tr>
                  </table>

                  <!-- Footer -->
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding-top: 30px; border-top: 1px solid #1f1f1f;">
                        <p style="margin: 0; color: #6b7280; font-size: 12px;">
                          - The #{app_name} Team
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

    {subject, text_body, html_body}
  end

  @doc """
  Verifies the recovery email token.
  If the user was restricted, also lifts the restriction.
  Returns {:ok, user} or {:error, reason}.
  """
  def verify_token(token) when is_binary(token) and byte_size(token) > 0 do
    case find_user_by_token(token) do
      nil ->
        {:error, :invalid_token}

      user ->
        if token_expired?(user) do
          {:error, :token_expired}
        else
          do_verify(user)
        end
    end
  end

  def verify_token(_), do: {:error, :invalid_token}

  @doc """
  Finds a user by their recovery email verification token.
  Returns the user or nil if not found.
  """
  def get_user_by_token(token) when is_binary(token) and byte_size(token) > 0 do
    Repo.get_by(User, recovery_email_verification_token: token)
  end

  def get_user_by_token(_), do: nil

  defp find_user_by_token(token) do
    Repo.get_by(User, recovery_email_verification_token: token)
  end

  defp token_expired?(user) do
    case user.recovery_email_verification_sent_at do
      nil ->
        true

      sent_at ->
        expiry = DateTime.add(sent_at, @token_validity_hours * 3600, :second)
        DateTime.compare(DateTime.utc_now(), expiry) == :gt
    end
  end

  defp do_verify(user) do
    # Always set recovery_email_verified to true
    # If user was restricted, also lift the restriction
    changes = %{
      recovery_email_verified: true,
      recovery_email_verification_token: nil,
      recovery_email_verification_sent_at: nil
    }

    # Add restriction lifting if user was restricted
    changes =
      if user.email_sending_restricted do
        Map.merge(changes, %{
          email_sending_restricted: false,
          email_rate_limit_violations: 0,
          email_restriction_reason: nil,
          email_restricted_at: nil
        })
      else
        changes
      end

    user
    |> Ecto.Changeset.change(changes)
    |> Repo.update()
    |> case do
      {:ok, updated_user} ->
        if user.email_sending_restricted do
          Logger.info("User #{user.id} verified recovery email and restriction lifted")
        else
          Logger.info("User #{user.id} verified recovery email")
        end

        {:ok, updated_user}

      error ->
        error
    end
  end

  @doc """
  Checks if a user's recovery email is verified.
  """
  def verified?(user_id) do
    case Repo.get(User, user_id) do
      nil -> false
      user -> user.recovery_email_verified == true
    end
  end

  @doc """
  Checks if a user needs to verify their recovery email.
  Returns true if they have a recovery email but it's not verified.
  """
  def needs_verification?(user_id) do
    case Repo.get(User, user_id) do
      nil ->
        false

      user ->
        has_recovery_email = !is_nil(user.recovery_email) && user.recovery_email != ""
        has_recovery_email && !user.recovery_email_verified
    end
  end

  @doc """
  Sets the recovery email for a user.
  Automatically marks it as unverified and sends verification email.
  """
  def set_recovery_email(user_id, email) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :user_not_found}

      user ->
        # Check if email is actually changing
        if user.recovery_email == email && user.recovery_email_verified do
          {:ok, user}
        else
          result =
            user
            |> Ecto.Changeset.change(%{
              recovery_email: email,
              recovery_email_verified: false,
              recovery_email_verification_token: nil,
              recovery_email_verification_sent_at: nil
            })
            |> Repo.update()

          # If successful and email is not empty, send verification
          case result do
            {:ok, updated_user} when email != nil and email != "" ->
              send_verification_email(updated_user.id)
              {:ok, updated_user}

            other ->
              other
          end
        end
    end
  end
end
