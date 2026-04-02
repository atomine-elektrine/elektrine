defmodule ElektrineWeb.Components.Social.PostActions do
  @moduledoc """
  Compatibility wrapper for the social app post actions component.
  """

  def post_actions(assigns) do
    ElektrineSocialWeb.Components.Social.PostActions.post_actions(assigns)
  end

  def like_button(assigns) do
    ElektrineSocialWeb.Components.Social.PostActions.like_button(assigns)
  end

  def comment_button(assigns) do
    ElektrineSocialWeb.Components.Social.PostActions.comment_button(assigns)
  end

  def boost_button(assigns) do
    ElektrineSocialWeb.Components.Social.PostActions.boost_button(assigns)
  end

  def vote_buttons(assigns) do
    ElektrineSocialWeb.Components.Social.PostActions.vote_buttons(assigns)
  end

  def save_button(assigns) do
    ElektrineSocialWeb.Components.Social.PostActions.save_button(assigns)
  end
end
