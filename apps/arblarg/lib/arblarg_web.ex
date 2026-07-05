defmodule ArblargWeb do
  @moduledoc """
  Shared web entrypoints for chat surfaces extracted from elektrine_web.
  """

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: ElektrineWeb.Layouts]

      use Gettext, backend: ElektrineWeb.Gettext

      import Plug.Conn

      alias Elektrine.Utils.SafeConvert

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {ElektrineWeb.Layouts, :app}

      on_mount ElektrineWeb.Live.AnnouncementCache

      import ElektrineWeb.Live.NotificationHelpers

      unquote(html_helpers())

      def handle_event("set_timezone", %{"timezone" => timezone}, socket) do
        {:noreply, assign(socket, :timezone, timezone)}
      end

      # Presence events are handled by ElektrineWeb's PresenceHook where it is
      # mounted; these no-op fallbacks keep stray client events from crashing
      # LiveViews that don't track presence.
      def handle_event(event, _params, socket)
          when event in [
                 "user_activity",
                 "auto_away_timeout",
                 "device_detected",
                 "connection_changed"
               ] do
        {:noreply, socket}
      end
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Gettext, backend: ElektrineWeb.Gettext

      import Phoenix.HTML
      import ElektrineWeb.CoreComponents
      import Elektrine.Components.User.Avatar
      import Elektrine.Components.Loaders.Skeleton
      import ArblargWeb.Components.UI.ImageModal

      alias Elektrine.Utils.SafeConvert
      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ElektrineWeb.Endpoint,
        router: ElektrineWeb.Router,
        statics: ElektrineWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
