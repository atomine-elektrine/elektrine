defmodule ElektrineWeb.RecoveryEmailHTML do
  @moduledoc """
  This module contains pages rendered by RecoveryEmailController.

  See the `recovery_email_html` directory for all templates.
  """
  use ElektrineWeb, :html

  embed_templates "recovery_email_html/*"
end
