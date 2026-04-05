defmodule ElektrineEmailWeb.UnsubscribeHTML do
  @moduledoc """
  This module contains pages rendered by UnsubscribeController.

  See the `unsubscribe_html` directory for all templates.
  """
  use ElektrineEmailWeb, :html

  embed_templates "unsubscribe_html/*"
end
