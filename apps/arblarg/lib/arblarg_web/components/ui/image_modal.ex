defmodule ArblargWeb.Components.UI.ImageModal do
  @moduledoc false

  alias ArblargWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.UI.ImageModal"

  def image_modal(assigns) do
    OptionalModule.call(:social, @component_module, :image_modal, [assigns], "")
  end
end
