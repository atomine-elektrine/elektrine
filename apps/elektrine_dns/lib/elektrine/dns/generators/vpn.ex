defmodule Elektrine.DNS.Generators.VPN do
  @moduledoc false

  def generate(zone, settings \\ %{}) do
    ttl = zone.default_ttl || 300

    primary = %{
      managed_key: "vpn:host",
      name: vpn_host_label(settings),
      type: "CNAME",
      ttl: ttl,
      content: vpn_target(zone, settings),
      required: false,
      metadata: %{"label" => "VPN endpoint alias"}
    }

    [primary | maybe_api_record(ttl, zone, settings)]
  end

  defp maybe_api_record(ttl, zone, settings) do
    case vpn_api_host_label(settings) do
      nil ->
        []

      host ->
        [
          %{
            managed_key: "vpn:api",
            name: host,
            type: "CNAME",
            ttl: ttl,
            content: vpn_api_target(zone, settings),
            required: false,
            metadata: %{"label" => "VPN admin/API alias"}
          }
        ]
    end
  end

  defp vpn_host_label(settings) do
    case Map.get(settings, "vpn_host") do
      value when is_binary(value) and value != "" -> normalize(value, "vpn")
      _ -> "vpn"
    end
  end

  defp vpn_target(zone, settings) do
    case Map.get(settings, "vpn_target") do
      value when is_binary(value) and value != "" -> normalize(value, zone.domain)
      _ -> zone.domain
    end
  end

  defp vpn_api_host_label(settings) do
    case Map.get(settings, "vpn_api_host") do
      value when is_binary(value) ->
        case normalize(value, "") do
          "" -> nil
          normalized -> normalized
        end

      _ ->
        nil
    end
  end

  defp vpn_api_target(zone, settings) do
    case Map.get(settings, "vpn_api_target") do
      value when is_binary(value) and value != "" -> normalize(value, zone.domain)
      _ -> zone.domain
    end
  end

  defp normalize(value, fallback) do
    case value |> String.trim() |> String.trim_trailing(".") |> String.downcase() do
      "" -> fallback
      normalized -> normalized
    end
  end
end
