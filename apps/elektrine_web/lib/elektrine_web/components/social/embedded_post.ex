defmodule ElektrineWeb.Components.Social.EmbeddedPost do
  @moduledoc """
  Compatibility wrapper for the social app embedded post component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.EmbeddedPost"

  def embedded_post(assigns) do
    OptionalModule.call(:social, @component_module, :embedded_post, [assigns], "")
  end
end
