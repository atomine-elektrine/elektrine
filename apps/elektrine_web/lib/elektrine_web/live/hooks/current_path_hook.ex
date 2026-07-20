defmodule ElektrineWeb.Live.Hooks.CurrentPathHook do
  @moduledoc """
  Assigns the LiveView URI as `:current_url` so layout helpers (full-width main,
  grid color, etc.) can resolve the path without relying on `host_uri`, which
  usually has no path.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     attach_hook(socket, :assign_current_url, :handle_params, fn _params, uri, socket ->
       {:cont, assign(socket, :current_url, uri)}
     end)}
  end
end
