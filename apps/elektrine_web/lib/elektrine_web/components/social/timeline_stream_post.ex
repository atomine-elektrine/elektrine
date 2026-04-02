defmodule ElektrineWeb.Components.Social.TimelineStreamPost do
  @moduledoc """
  Compatibility wrapper for the social app timeline stream component.
  """

  use Phoenix.LiveComponent

  @impl true
  def update(assigns, socket) do
    ElektrineSocialWeb.Components.Social.TimelineStreamPost.update(assigns, socket)
  end

  @impl true
  def render(assigns) do
    ElektrineSocialWeb.Components.Social.TimelineStreamPost.render(assigns)
  end
end
