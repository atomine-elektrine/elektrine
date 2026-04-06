defmodule ElektrineWeb.Components.User.HoverCard do
  @moduledoc """
  Compatibility wrapper for the social app user hover card component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.User.HoverCard"

  def user_hover_card(assigns) do
    OptionalModule.call(:social, @component_module, :user_hover_card, [assigns], "")
  end
end
