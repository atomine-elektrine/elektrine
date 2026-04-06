defmodule ElektrineWeb.Components.Social.RSSItem do
  @moduledoc """
  Compatibility wrapper for the social app RSS item component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.RSSItem"

  def rss_item(assigns) do
    OptionalModule.call(:social, @component_module, :rss_item, [assigns], "")
  end
end
