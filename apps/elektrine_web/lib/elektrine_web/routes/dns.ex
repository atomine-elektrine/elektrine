defmodule ElektrineWeb.Routes.DNS do
  @moduledoc false

  defmacro api_read_routes do
    quote do
      scope "/", alias: false do
        get("/zones", ElektrineDNSWeb.API.DNSController, :index)
        get("/zones/:id", ElektrineDNSWeb.API.DNSController, :show)
      end
    end
  end

  defmacro api_write_routes do
    quote do
      scope "/", alias: false do
        post("/zones", ElektrineDNSWeb.API.DNSController, :create)
        put("/zones/:id", ElektrineDNSWeb.API.DNSController, :update)
        delete("/zones/:id", ElektrineDNSWeb.API.DNSController, :delete)
        post("/zones/:id/verify", ElektrineDNSWeb.API.DNSController, :verify)

        post(
          "/zones/:id/services/:service/apply",
          ElektrineDNSWeb.API.DNSController,
          :apply_service
        )

        delete(
          "/zones/:id/services/:service",
          ElektrineDNSWeb.API.DNSController,
          :disable_service
        )

        post("/zones/:zone_id/records", ElektrineDNSWeb.API.DNSController, :create_record)
        put("/zones/:zone_id/records/:id", ElektrineDNSWeb.API.DNSController, :update_record)
        delete("/zones/:zone_id/records/:id", ElektrineDNSWeb.API.DNSController, :delete_record)
      end
    end
  end

  defmacro main_live_routes do
    quote do
      scope "/", alias: false do
        live("/dns", ElektrineDNSWeb.DNSLive.Index, :index)
      end
    end
  end

  def path_prefixes do
    ["/dns", "/api/dns", "/api/ext/v1/dns", "/api/ext/dns", "/pripyat/dns"]
  end

  def view_modules do
    [ElektrineDNSWeb.DNSLive.Index]
  end
end
