defmodule ElektrineWeb.Components.Social.PostReactions do
  @moduledoc """
  Compatibility wrapper for the social app post reactions component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.PostReactions"

  def post_reactions(assigns) do
    OptionalModule.call(:social, @component_module, :post_reactions, [assigns], "")
  end
end
