defmodule ElektrineWeb.PageHTML do
  @moduledoc """
  This module contains public pages rendered by PageController.
  """
  use ElektrineWeb, :html

  embed_templates "page_html/*"
end
