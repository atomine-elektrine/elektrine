defmodule ElektrineWeb.Components.User.HoverCard do
  @moduledoc """
  Compatibility wrapper for the social app user hover card component.
  """

  def user_hover_card(assigns) do
    ElektrineSocialWeb.Components.User.HoverCard.user_hover_card(assigns)
  end
end
