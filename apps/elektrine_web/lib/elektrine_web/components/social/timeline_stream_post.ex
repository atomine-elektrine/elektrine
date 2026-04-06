defmodule ElektrineWeb.Components.Social.TimelineStreamPost do
  @moduledoc """
  Compatibility wrapper for the social app timeline stream component.
  """

  use Phoenix.LiveComponent

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.TimelineStreamPost"

  @impl true
  def update(assigns, socket) do
    OptionalModule.call(
      :social,
      @component_module,
      :update,
      [assigns, socket],
      {:ok, assign(socket, assigns)}
    )
  end

  @impl true
  def render(assigns) do
    OptionalModule.call(:social, @component_module, :render, [assigns], ~H"")
  end
end
