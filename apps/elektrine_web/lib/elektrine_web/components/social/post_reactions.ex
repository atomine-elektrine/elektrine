defmodule ElektrineWeb.Components.Social.PostReactions do
  @moduledoc """
  Compatibility wrapper for the social app post reactions component.
  """

  def post_reactions(assigns) do
    ElektrineSocialWeb.Components.Social.PostReactions.post_reactions(assigns)
  end
end
