defmodule ElektrineWeb.Components.Social.TimelinePost do
  @moduledoc """
  Compatibility wrapper for the social app timeline post component.
  """

  def timeline_post(assigns) do
    ElektrineSocialWeb.Components.Social.TimelinePost.timeline_post(assigns)
  end
end
