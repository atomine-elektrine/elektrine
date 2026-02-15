defmodule ElektrineWeb.PasswordResetHTML do
  @moduledoc """
  This module contains pages rendered by PasswordResetController.

  See the `password_reset_html` directory for all templates.
  """
  use ElektrineWeb, :html

  embed_templates "password_reset_html/*"
end
