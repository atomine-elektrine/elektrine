defmodule ElektrineWeb.Components.Social.FollowButton do
  @moduledoc """
  Compatibility wrapper for the social app follow button component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.FollowButton"

  def local_follow_button(assigns) do
    OptionalModule.call(:social, @component_module, :local_follow_button, [assigns], "")
  end
end
