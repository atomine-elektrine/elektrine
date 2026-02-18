defmodule ElektrineChatWeb do
  @moduledoc """
  Entrypoint for the dedicated chat/auth API surface.
  """

  def static_paths, do: []

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ElektrineChatWeb.Endpoint,
        router: ElektrineChatWeb.Router,
        statics: ElektrineChatWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
