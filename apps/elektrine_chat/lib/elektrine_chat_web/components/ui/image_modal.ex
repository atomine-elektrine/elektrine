defmodule ElektrineChatWeb.Components.UI.ImageModal do
  @moduledoc false

  alias ElektrineChatWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.UI.ImageModal"

  def image_modal(assigns) do
    OptionalModule.call(:social, @component_module, :image_modal, [assigns], "")
  end
end
