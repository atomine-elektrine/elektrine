defmodule ElektrineDNSWeb do
  @moduledoc """
  Shared web entrypoints for DNS surfaces extracted from elektrine_web.
  """

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: ElektrineWeb.Layouts]

      use Gettext, backend: ElektrineWeb.Gettext

      import Plug.Conn

      use Phoenix.VerifiedRoutes,
        endpoint: ElektrineWeb.Endpoint,
        router: ElektrineWeb.Router,
        statics: ElektrineWeb.static_paths()
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {ElektrineWeb.Layouts, :app}

      on_mount ElektrineWeb.Live.AnnouncementCache

      import ElektrineWeb.Live.NotificationHelpers

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Gettext, backend: ElektrineWeb.Gettext

      import Phoenix.HTML
      import ElektrineWeb.CoreComponents
      import ElektrineWeb.Components.Platform.ENav

      alias Phoenix.LiveView.JS

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
