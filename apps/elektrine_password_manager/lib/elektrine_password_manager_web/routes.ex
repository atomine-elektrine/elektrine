defmodule ElektrinePasswordManagerWeb.Routes do
  @moduledoc """
  Router macros for the extracted password manager web surface.
  """

  defmacro live_routes do
    live_view = ElektrinePasswordManagerWeb.VaultLive

    quote do
      scope "/", alias: false do
        live("/account/password-manager", unquote(Macro.escape(live_view)), :index)
      end
    end
  end

  defmacro api_read_routes do
    controller = ElektrinePasswordManagerWeb.API.VaultController

    quote do
      scope "/", alias: false do
        get("/entries", unquote(Macro.escape(controller)), :index)
        get("/entries/:id", unquote(Macro.escape(controller)), :show)
      end
    end
  end

  defmacro api_write_routes do
    controller = ElektrinePasswordManagerWeb.API.VaultController

    quote do
      scope "/", alias: false do
        post("/vault/setup", unquote(Macro.escape(controller)), :setup)
        post("/entries", unquote(Macro.escape(controller)), :create)
        delete("/entries/:id", unquote(Macro.escape(controller)), :delete)
      end
    end
  end
end
