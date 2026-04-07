defmodule ElektrineWeb.Routes.Vault do
  @moduledoc false

  defmacro live_routes do
    quote do
      scope "/", alias: false do
        live("/account/password-manager", ElektrinePasswordManagerWeb.VaultLive, :index)
      end
    end
  end

  defmacro api_read_routes do
    quote do
      scope "/", alias: false do
        get("/entries", ElektrinePasswordManagerWeb.API.VaultController, :index)
        get("/entries/:id", ElektrinePasswordManagerWeb.API.VaultController, :show)
      end
    end
  end

  defmacro api_write_routes do
    quote do
      scope "/", alias: false do
        post("/vault/setup", ElektrinePasswordManagerWeb.API.VaultController, :setup)
        delete("/vault", ElektrinePasswordManagerWeb.API.VaultController, :delete_vault)
        post("/entries", ElektrinePasswordManagerWeb.API.VaultController, :create)
        put("/entries/:id", ElektrinePasswordManagerWeb.API.VaultController, :update)
        delete("/entries/:id", ElektrinePasswordManagerWeb.API.VaultController, :delete)
      end
    end
  end

  def path_prefixes do
    [
      "/account/password-manager",
      "/api/ext/v1/password-manager",
      "/api/ext/password-manager"
    ]
  end

  def view_modules do
    [ElektrinePasswordManagerWeb.VaultLive]
  end
end
