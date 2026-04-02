defmodule ElektrineWeb.Components.Email.Display do
  @moduledoc "Email display and processing utilities for sanitizing and formatting email content."

  defdelegate process_email_html(html_content), to: ElektrineEmailWeb.Components.Email.Display
  defdelegate clean_email_artifacts(content), to: ElektrineEmailWeb.Components.Email.Display
  defdelegate format_email_display(email_string), to: ElektrineEmailWeb.Components.Email.Display

  defdelegate safe_sanitize_email_html(html_content),
    to: ElektrineEmailWeb.Components.Email.Display

  defdelegate permissive_email_sanitize(html_content),
    to: ElektrineEmailWeb.Components.Email.Display

  defdelegate safe_message_to_json(message), to: ElektrineEmailWeb.Components.Email.Display
  defdelegate decode_email_subject(subject), to: ElektrineEmailWeb.Components.Email.Display
end
