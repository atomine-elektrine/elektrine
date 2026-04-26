defmodule ElektrineWeb.Live.Hooks.PlatformModuleHook do
  @moduledoc """
  Guards module-specific LiveViews during websocket navigation.

  The HTTP plug handles direct requests; this hook covers live navigations that
  stay inside the shared `:main` live_session.
  """

  import Phoenix.LiveView
  use ElektrineWeb, :verified_routes

  alias ElektrineWeb.PlatformAccess

  def on_mount(:default, _params, _session, socket) do
    if PlatformAccess.accessible_view?(socket.view, socket.assigns[:current_user]) do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: ~p"/")}
    end
  end
end
