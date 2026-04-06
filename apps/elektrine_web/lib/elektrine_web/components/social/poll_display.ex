defmodule ElektrineWeb.Components.Social.PollDisplay do
  @moduledoc """
  Compatibility wrapper for the social app poll display component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.PollDisplay"

  def poll_card(assigns) do
    OptionalModule.call(:social, @component_module, :poll_card, [assigns], "")
  end
end
