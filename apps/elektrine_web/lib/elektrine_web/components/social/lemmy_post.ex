defmodule ElektrineWeb.Components.Social.LemmyPost do
  @moduledoc """
  Compatibility wrapper for the social app Lemmy post component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.LemmyPost"

  def lemmy_post(assigns) do
    OptionalModule.call(:social, @component_module, :lemmy_post, [assigns], "")
  end
end
