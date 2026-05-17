defmodule ElektrineWeb.Routes.Nerve do
  @moduledoc false

  defmacro live_routes do
    quote do
      scope "/", alias: false do
        live("/account/nerve", ElektrineNerveWeb.NerveLive, :index)
      end
    end
  end

  defmacro api_read_routes do
    quote do
      scope "/", alias: false do
        get("/entries", ElektrineNerveWeb.API.NerveController, :index)
        get("/entries/:id", ElektrineNerveWeb.API.NerveController, :show)
      end
    end
  end

  defmacro api_write_routes do
    quote do
      scope "/", alias: false do
        post("/setup", ElektrineNerveWeb.API.NerveController, :setup)
        delete("/", ElektrineNerveWeb.API.NerveController, :delete_nerve)
        post("/entries", ElektrineNerveWeb.API.NerveController, :create)
        put("/entries/:id", ElektrineNerveWeb.API.NerveController, :update)
        delete("/entries/:id", ElektrineNerveWeb.API.NerveController, :delete)
      end
    end
  end

  def path_prefixes do
    [
      "/account/nerve",
      "/api/ext/v1/nerve",
      "/api/ext/nerve"
    ]
  end

  def view_modules do
    [ElektrineNerveWeb.NerveLive]
  end
end
