defmodule ElektrineWeb.Components.Social.PostActions do
  @moduledoc """
  Compatibility wrapper for the social app post actions component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.PostActions"

  def post_actions(assigns) do
    OptionalModule.call(:social, @component_module, :post_actions, [assigns], "")
  end

  def like_button(assigns) do
    OptionalModule.call(:social, @component_module, :like_button, [assigns], "")
  end

  def comment_button(assigns) do
    OptionalModule.call(:social, @component_module, :comment_button, [assigns], "")
  end

  def boost_button(assigns) do
    OptionalModule.call(:social, @component_module, :boost_button, [assigns], "")
  end

  def vote_buttons(assigns) do
    OptionalModule.call(:social, @component_module, :vote_buttons, [assigns], "")
  end

  def save_button(assigns) do
    OptionalModule.call(:social, @component_module, :save_button, [assigns], "")
  end
end
