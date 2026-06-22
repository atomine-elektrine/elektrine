defmodule ElektrineWeb.Routes.Uptime do
  @moduledoc false

  defmacro main_live_routes do
    quote do
      scope "/", alias: false do
        live("/uptime", ElektrineUptimeWeb.UptimeLive.Index, :index)
      end
    end
  end

  def path_prefixes do
    ["/uptime"]
  end

  def view_modules do
    [ElektrineUptimeWeb.UptimeLive.Index]
  end
end
