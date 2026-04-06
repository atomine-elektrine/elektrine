defmodule ElektrineWeb.Components.Social.ContentJourney do
  @moduledoc """
  Compatibility wrapper for the social app content journey component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.ContentJourney"

  def content_journey(assigns) do
    OptionalModule.call(:social, @component_module, :content_journey, [assigns], "")
  end
end
