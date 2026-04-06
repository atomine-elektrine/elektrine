defmodule ElektrineWeb.Components.Social.TimelinePost do
  @moduledoc """
  Compatibility wrapper for the social app timeline post component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.TimelinePost"

  def timeline_post(assigns) do
    OptionalModule.call(:social, @component_module, :timeline_post, [assigns], "")
  end
end
