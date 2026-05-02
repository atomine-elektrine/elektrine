defmodule ArblargWeb.Components.Social.ContentJourney do
  @moduledoc false

  alias ArblargWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.ContentJourney"

  def content_journey(assigns) do
    OptionalModule.call(:social, @component_module, :content_journey, [assigns], "")
  end
end
