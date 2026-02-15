defmodule ElektrineWeb.Live.AnnouncementCache do
  @moduledoc """
  LiveView hook to cache announcements and prevent repeated database queries.
  Now loads announcements on both static and connected renders to prevent flickering.
  """

  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    # Load announcements on both static and connected renders
    # Caching in Elektrine.Admin ensures this is efficient
    announcements =
      case socket.assigns[:current_user] do
        nil -> []
        user -> ElektrineWeb.Layouts.get_active_announcements_for_user(user.id)
      end

    {:cont, assign(socket, :active_announcements, announcements)}
  end
end
