defmodule ElektrineWeb.Components.Social.FollowButton do
  @moduledoc """
  Compatibility wrapper for the social app follow button component.
  """

  def local_follow_button(assigns) do
    ElektrineSocialWeb.Components.Social.FollowButton.local_follow_button(assigns)
  end
end
