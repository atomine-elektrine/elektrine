defmodule Elektrine.DNS.Generators.Turn do
  @moduledoc false

  def generate(zone, settings \\ %{}) do
    ttl = zone.default_ttl || 300

    [
      %{
        managed_key: "turn:host",
        name: turn_host_label(settings),
        type: "CNAME",
        ttl: ttl,
        content: turn_target(zone, settings),
        required: false,
        metadata: %{"label" => "TURN host alias"}
      }
    ]
  end

  defp turn_host_label(settings) do
    case Map.get(settings, "turn_host") do
      value when is_binary(value) and value != "" -> normalize(value, "turn")
      _ -> "turn"
    end
  end

  defp turn_target(zone, settings) do
    case Map.get(settings, "turn_target") do
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
