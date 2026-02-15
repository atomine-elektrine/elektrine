defmodule ElektrineWeb do
  @moduledoc """
  Entrypoint for web interface modules (controllers, components, channels, etc).

  This can be used in your application as:

      use ElektrineWeb, :controller
      use ElektrineWeb, :html

  Keep quoted blocks focused on imports, aliases, and `use` declarations.
  """

  def static_paths, do: ~w(assets fonts images uploads favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

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
        socket = assign(socket, :timezone, timezone)
        {:noreply, socket}
      end

      def handle_event("user_activity", params, socket) do
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(
          "user_activity",
          params,
          socket
        )
      end

      def handle_event("auto_away_timeout", params, socket) do
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(
          "auto_away_timeout",
          params,
          socket
        )
      end

      def handle_event("device_detected", params, socket) do
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(
          "device_detected",
          params,
          socket
        )
      end

      def handle_event("connection_changed", params, socket) do
        ElektrineWeb.Live.Hooks.PresenceEvents.handle_presence_event(
          "connection_changed",
          params,
          socket
        )
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
      import ElektrineWeb.Components.User.Avatar
      import ElektrineWeb.Components.Loaders.Skeleton
      import ElektrineWeb.Components.UI.ImageModal
      import ElektrineWeb.Components.Social.PostActions
      import ElektrineWeb.Components.Social.PostReactions
      import ElektrineWeb.Components.Social.FediverseFollow

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
