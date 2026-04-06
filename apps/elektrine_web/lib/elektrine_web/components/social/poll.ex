defmodule ElektrineWeb.Components.Social.Poll do
  @moduledoc """
  Compatibility wrapper for the social app poll component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.Poll"

  def poll_display(assigns) do
    OptionalModule.call(:social, @component_module, :poll_display, [assigns], "")
  end
end
