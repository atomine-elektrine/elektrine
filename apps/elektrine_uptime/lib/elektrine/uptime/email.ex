defmodule Elektrine.Uptime.Email do
  @moduledoc """
  Swoosh email builders for uptime monitor alerts (down / recovered).

  Modeled on `Elektrine.UserNotifier`: same from-address and themed
  html/text bodies. Delivered via `Elektrine.Mailer.deliver_later/1`.
  """

  import Swoosh.Email

  alias Elektrine.EmailAddresses
  alias Elektrine.Theme
  alias Elektrine.Uptime.Check
  alias Elektrine.Uptime.Monitor

  @doc """
  Email sent when a monitor crosses its failure threshold (goes down).
  """
  def down_email(user, %Monitor{} = monitor, %Check{} = check) do
    reason = check.error || "Check failed"

    new()
    |> to(user.recovery_email)
    |> from(system_from_email())
    |> subject("[Down] #{monitor.name}")
    |> html_body(down_html_body(user, monitor, reason))
    |> text_body(down_text_body(monitor, reason))
    |> header("List-Id", EmailAddresses.list_id("elektrine-uptime"))
  end

  @doc """
  Email sent when a monitor recovers (comes back up).
  """
  def recovery_email(user, %Monitor{} = monitor) do
    new()
    |> to(user.recovery_email)
    |> from(system_from_email())
    |> subject("[Recovered] #{monitor.name}")
    |> html_body(recovery_html_body(user, monitor))
    |> text_body(recovery_text_body(monitor))
    |> header("List-Id", EmailAddresses.list_id("elektrine-uptime"))
  end

  defp down_html_body(user, monitor, reason) do
    body(user, :error, "#{monitor.name} is down", [
      "We couldn't reach <strong>#{escape(monitor.target)}</strong>.",
      "Reason: #{escape(reason)}"
    ])
  end

  defp recovery_html_body(user, monitor) do
    body(user, :success, "#{monitor.name} recovered", [
      "<strong>#{escape(monitor.target)}</strong> is responding again."
    ])
  end

  defp down_text_body(monitor, reason) do
    """
    #{monitor.name} is down

    We couldn't reach #{monitor.target}.
    Reason: #{reason}

    View your monitors: #{uptime_url()}

    This is an automated message from Elektrine. Please do not reply to this email.
    """
  end

  defp recovery_text_body(monitor) do
    """
    #{monitor.name} recovered

    #{monitor.target} is responding again.

    View your monitors: #{uptime_url()}

    This is an automated message from Elektrine. Please do not reply to this email.
    """
  end

  defp body(user, variant, heading, paragraphs) do
    palette = Theme.email_palette(user, variant)
    url = uptime_url()

    paragraph_html =
      Enum.map_join(paragraphs, "\n", fn text ->
        ~s(<p style="margin: 0 0 16px 0; color: #{palette.text_body}; font-size: 16px; line-height: 1.6;">#{text}</p>)
      end)

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <meta name="color-scheme" content="dark">
      <meta name="supported-color-schemes" content="dark">
    </head>
    <body style="margin: 0; padding: 0; background-color: #{palette.page_bg}; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #{palette.page_bg};">
        <tr>
          <td align="center" style="padding: 40px 20px;">
            <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width: 600px; background-color: #{palette.card_bg}; border: 1px solid #{palette.card_border}; border-radius: 12px;">
              <tr>
                <td style="padding: 40px;">
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding-bottom: 30px; border-bottom: 1px solid #{palette.divider};">
                        <h1 style="margin: 0; color: #{palette.text_heading}; font-size: 24px; font-weight: 600;">#{escape(heading)}</h1>
                      </td>
                    </tr>
                  </table>

                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding: 30px 0;">
                        #{paragraph_html}

                        <table role="presentation" cellpadding="0" cellspacing="0" style="margin: 20px 0;">
                          <tr>
                            <td style="background-color: #{palette.button_bg}; border-radius: 8px;">
                              <a href="#{url}" style="display: inline-block; padding: 14px 28px; color: #{palette.button_text}; text-decoration: none; font-size: 16px; font-weight: 600;">
                                View Your Monitors
                              </a>
                            </td>
                          </tr>
                        </table>
                      </td>
                    </tr>
                  </table>

                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td style="padding-top: 30px; border-top: 1px solid #{palette.divider};">
                        <p style="margin: 0; color: #{palette.text_subtle}; font-size: 12px;">
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

  defp uptime_url, do: ElektrineWeb.Endpoint.url() <> "/uptime"

  defp escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp system_from_email do
    {"Elektrine", EmailAddresses.local("noreply")}
  end
end
