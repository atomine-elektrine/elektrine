defmodule ElektrinePasswordManagerWeb do
  @moduledoc """
  Shared web entrypoints for password manager surfaces extracted from elektrine_web.
  """

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: ElektrineWeb.Layouts]

      use Gettext, backend: ElektrineWeb.Gettext

      import Plug.Conn
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {ElektrineWeb.Layouts, :app}

      unquote(html_helpers())

      def handle_event("set_timezone", %{"timezone" => timezone}, socket) do
        {:noreply, assign(socket, :timezone, timezone)}
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
      import Phoenix.HTML.Form

      alias Phoenix.LiveView.JS
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
