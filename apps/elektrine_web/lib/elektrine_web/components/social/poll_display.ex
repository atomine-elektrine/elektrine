defmodule ElektrineWeb.Components.Social.PollDisplay do
  @moduledoc """
  Compatibility wrapper for the social app poll display component.
  """

  def poll_card(assigns) do
    ElektrineSocialWeb.Components.Social.PollDisplay.poll_card(assigns)
  end
end
