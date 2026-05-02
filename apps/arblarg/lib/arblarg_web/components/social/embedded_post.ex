defmodule ArblargWeb.Components.Social.EmbeddedPost do
  @moduledoc false

  alias ArblargWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.EmbeddedPost"

  def embedded_post(assigns) do
    OptionalModule.call(:social, @component_module, :embedded_post, [assigns], "")
  end
end
