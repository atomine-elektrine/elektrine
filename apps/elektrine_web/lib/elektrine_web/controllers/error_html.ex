defmodule ElektrineWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use ElektrineWeb, :html

  # Custom error pages for better user experience
  # Templates are located in lib/elektrine_web/controllers/error_html/
  embed_templates "error_html/*"

  # Fallback for other error codes that don't have custom templates
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
