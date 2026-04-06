defmodule ElektrineWeb.Components.UI.ImageModal do
  @moduledoc """
  Compatibility wrapper for the social app image modal component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.UI.ImageModal"

  def image_modal(assigns) do
    OptionalModule.call(:social, @component_module, :image_modal, [assigns], "")
  end
end
