defmodule ElektrineWeb.Components.Social.EmbeddedPost do
  @moduledoc """
  Compatibility wrapper for the social app embedded post component.
  """

  def embedded_post(assigns) do
    ElektrineSocialWeb.Components.Social.EmbeddedPost.embedded_post(assigns)
  end
end
