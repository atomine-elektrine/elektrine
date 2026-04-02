defmodule ElektrineWeb.Components.Social.LemmyPost do
  @moduledoc """
  Compatibility wrapper for the social app Lemmy post component.
  """

  def lemmy_post(assigns) do
    ElektrineSocialWeb.Components.Social.LemmyPost.lemmy_post(assigns)
  end
end
