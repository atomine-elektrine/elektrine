defmodule ElektrineWeb.Live.Hooks.CurrentPathHook do
  @moduledoc """
  Assigns the LiveView URI as `:current_url` so layout helpers (full-width main,
  grid color, etc.) can resolve the path without relying on `host_uri`, which
  usually has no path.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    # :handle_params hooks require a router-mounted LiveView (live/3).
    # Controllers that live_render/3 have socket.router == nil.
    if socket.router do
      {:cont,
       attach_hook(socket, :assign_current_url, :handle_params, fn _params, uri, socket ->
         {:cont, assign(socket, :current_url, uri)}
       end)}
    else
      {:cont, socket}
    end
  end
end
