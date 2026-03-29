defmodule Elektrine.DNS.Generators.Web do
  @moduledoc false

  def generate(zone, settings \\ %{}) do
    target = web_target(zone, settings)
    ttl = zone.default_ttl || 300

    [
      %{
        managed_key: "web:www",
        name: "www",
        type: "CNAME",
        ttl: ttl,
        content: target,
        required: false,
        metadata: %{"label" => "WWW alias"}
      }
    ]
  end

  defp web_target(zone, settings) do
    case Map.get(settings, "www_target") do
      value when is_binary(value) and value != "" -> value
      _ -> zone.domain
    end
  end
end
