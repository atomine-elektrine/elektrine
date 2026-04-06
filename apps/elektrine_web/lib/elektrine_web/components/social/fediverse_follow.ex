defmodule ElektrineWeb.Components.Social.FediverseFollow do
  @moduledoc """
  Compatibility wrapper for the social app fediverse follow component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.FediverseFollow"

  def fediverse_follow(assigns) do
    OptionalModule.call(:social, @component_module, :fediverse_follow, [assigns], "")
  end

  def actor_preview(assigns) do
    OptionalModule.call(:social, @component_module, :actor_preview, [assigns], "")
  end

  def fediverse_follow_inline(assigns) do
    OptionalModule.call(:social, @component_module, :fediverse_follow_inline, [assigns], "")
  end
end
