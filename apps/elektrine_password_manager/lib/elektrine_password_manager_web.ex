defmodule ElektrinePasswordManagerWeb do
  @moduledoc """
  Minimal web entrypoints for extracted password manager surfaces.
  """

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {ElektrineWeb.Layouts, :app}

      import Phoenix.Component
      import Phoenix.LiveView
      import Phoenix.HTML.Form
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
